import XCTest
@testable import FrontbotCore

final class LocalDateToolTests: XCTestCase {
    func testDraftAcceptsDateTimeWithoutOffsetAsLocalTime() throws {
        let db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        let brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let handler = ToolHandler(db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
        _ = try handler.handle(method: "tool.posts_create_draft", params: [
            "brand_id": .string(brand.id), "network": "instagram", "body": "hola", "scheduled_for": "2026-10-20T21:30:00",
        ])
        let at = try XCTUnwrap(try db.posts(brandId: brand.id, status: nil).first?.scheduledFor)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 10, 20, 21, 30])
    }
}
