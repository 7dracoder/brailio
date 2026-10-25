import {test} from 'node:test';
import assert from 'node:assert/strict';
import handler,{validateRoute,routePayload,parseRoute} from '../api/route.js';
const coordinates={origin:{latitude:37,longitude:-122},destination:{latitude:37.01,longitude:-122}};
test('Google route accepts only finite bounded coordinates',()=>{
 assert.deepEqual(validateRoute(coordinates),coordinates);
 for(const body of [{}, {...coordinates,origin:{latitude:91,longitude:0}}, {...coordinates,destination:{latitude:NaN,longitude:0}}]) assert.throws(()=>validateRoute(body));
});
test('Google payload requests walking with detailed geometry and no credentials',()=>{
 const payload=routePayload(coordinates);assert.equal(payload.travelMode,'WALK');assert.equal(payload.polylineQuality,'HIGH_QUALITY');assert.equal(JSON.stringify(payload).includes('KEY'),false);
});
test('Google output requires usable geometry and instructions',()=>{
 const route=parseRoute({routes:[{polyline:{encodedPolyline:'abcd'},legs:[{steps:[{navigationInstruction:{instructions:'Turn right'},polyline:{encodedPolyline:'efgh'}}]}]}]});
 assert.equal(route.provider,'google');assert.equal(route.steps[0].instructions,'Turn right');assert.throws(()=>parseRoute({routes:[]}));
 assert.throws(()=>parseRoute({routes:[{polyline:{encodedPolyline:'abcd'},legs:[]}]}));
});
test('Unauthenticated routing never reaches Google',async()=>{
 let status;const res={setHeader(){},status(value){status=value;return this},json(){return this}};
 await handler({method:'POST',headers:{},body:coordinates},res);assert.equal(status,401);
});
test('Missing Google key is an explicit setup response',async()=>{
 const oldToken=process.env.BRAILIO_APP_TOKEN,oldKey=process.env.GOOGLE_MAPS_API_KEY;
 process.env.BRAILIO_APP_TOKEN='test-token';delete process.env.GOOGLE_MAPS_API_KEY;
 try {let status,body;const res={setHeader(){},status(value){status=value;return this},json(value){body=value;return this}};await handler({method:'POST',headers:{authorization:'Bearer test-token'},body:coordinates},res);assert.equal(status,503);assert.match(body.error,/setup/)}
 finally {if(oldToken===undefined)delete process.env.BRAILIO_APP_TOKEN;else process.env.BRAILIO_APP_TOKEN=oldToken;if(oldKey===undefined)delete process.env.GOOGLE_MAPS_API_KEY;else process.env.GOOGLE_MAPS_API_KEY=oldKey}
});
