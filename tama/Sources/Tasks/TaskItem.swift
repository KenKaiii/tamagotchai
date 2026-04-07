import Foundation

struct TaskItem: Codable, Identifiable {
    var id: UUID
    var title: String
    var isCompleted: Bool
}

struct TaskList: Codable, Identifiable {
    var id: UUID
    var title: String
    var items: [TaskItem]
    var createdAt: Date
    var updatedAt: Date
    var moodIcon: String
}
