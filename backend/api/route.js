import { authorized } from './assist.js';
const windows = new Map();
export function validateRoute(body) {
  for (const key of ['origin', 'destination']) {
    const p = body?.[key];
    if (!p || !Number.isFinite(p.latitude) || Math.abs(p.latitude) > 90 || !Number.isFinite(p.longitude) || Math.abs(p.longitude) > 180) throw Error('Valid origin and destination coordinates are required');
  }
  return { origin: body.origin, destination: body.destination };
}
export function routePayload(body) {
  const waypoint = p => ({location:{latLng:{latitude:p.latitude,longitude:p.longitude}}});
  return {origin:waypoint(body.origin),destination:waypoint(body.destination),travelMode:'WALK',computeAlternativeRoutes:false,languageCode:'en-US',units:'METRIC',polylineQuality:'HIGH_QUALITY'};
}
export function parseRoute(result) {
  const route = result.routes?.[0];
  const polyline = route?.polyline?.encodedPolyline;
  if (typeof polyline !== 'string' || polyline.length < 4 || polyline.length > 200_000) throw Error('No usable walking route');
  const steps = (route.legs ?? []).flatMap(leg => leg.steps ?? []).map(step => ({instructions:step.navigationInstruction?.instructions,polyline:step.polyline?.encodedPolyline ?? ''})).filter(step => typeof step.instructions === 'string' && step.instructions.trim());
  if (!steps.length || steps.length > 500 || steps.some(step => step.instructions.length > 2000 || typeof step.polyline !== 'string' || step.polyline.length > 200_000)) throw Error('Invalid walking instructions');
  return {provider:'google',polyline,steps};
}
export default async function handler(req,res) {
  res.setHeader('Cache-Control','no-store');
  if(req.method!=='POST') return res.status(405).json({error:'POST required'});
  if(!authorized(req.headers.authorization,process.env.BRAILIO_APP_TOKEN)) return res.status(401).json({error:'Access token required'});
  if(!process.env.GOOGLE_MAPS_API_KEY) return res.status(503).json({error:'Google routing needs server setup. Choose Apple Maps or open Google Maps.'});
  let body; try {body=validateRoute(typeof req.body==='string'?JSON.parse(req.body):req.body)} catch(error) {return res.status(400).json({error:error.message})}
  const minute=Math.floor(Date.now()/60_000);for(const key of windows.keys()) if(key!==minute) windows.delete(key);
  if((windows.get(minute)||0)>=12) return res.status(429).json({error:'Wait before requesting another route'});
  windows.set(minute,(windows.get(minute)||0)+1);
  try {
    const upstream=await fetch('https://routes.googleapis.com/directions/v2:computeRoutes',{
      method:'POST',headers:{'Content-Type':'application/json','X-Goog-Api-Key':process.env.GOOGLE_MAPS_API_KEY,'X-Goog-FieldMask':'routes.polyline.encodedPolyline,routes.legs.steps.navigationInstruction.instructions,routes.legs.steps.polyline.encodedPolyline'},
      body:JSON.stringify(routePayload(body)),signal:AbortSignal.timeout(20_000)
    });
    if(!upstream.ok) return res.status(502).json({error:'Google could not calculate this walking route'});
    return res.status(200).json(parseRoute(await upstream.json()));
  } catch {return res.status(502).json({error:'Google walking route is unavailable. Retry or choose Apple Maps.'})}
}
