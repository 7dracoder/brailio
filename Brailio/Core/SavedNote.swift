import Foundation

struct SavedNote: Codable, Identifiable { let id: UUID; let text: String; let date: Date }
