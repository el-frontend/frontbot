// Fills an EMPTY Frontbot data folder with English demo content for product screenshots.
//
//   FRONTBOT_DATA_DIR=/tmp/frontbot-demo swift run FrontbotDemoSeed
//
// Refuses to run without FRONTBOT_DATA_DIR or when the folder already has a frontbot.sqlite,
// so it can never touch real data. Uses only the public FrontbotCore APIs the app itself uses.

import Foundation
import FrontbotCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FrontbotDemoSeed: \(message)\n".utf8))
    exit(1)
}

guard let dir = ProcessInfo.processInfo.environment["FRONTBOT_DATA_DIR"], !dir.isEmpty else {
    fail("FRONTBOT_DATA_DIR is not set. Point it at an empty folder, e.g. FRONTBOT_DATA_DIR=/tmp/frontbot-demo swift run FrontbotDemoSeed")
}
let paths = AppPaths.standard()
guard paths.root.standardizedFileURL.path == URL(fileURLWithPath: dir, isDirectory: true).standardizedFileURL.path else {
    fail("AppPaths.standard() did not resolve to FRONTBOT_DATA_DIR; refusing to continue.")
}
guard !FileManager.default.fileExists(atPath: paths.database.path) else {
    fail("\(paths.database.path) already exists. The seeder only fills an empty folder; pick a new FRONTBOT_DATA_DIR.")
}

let calendar = Calendar.current
let now = Date()

func day(_ offsetFromMonday: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    let today = calendar.startOfDay(for: now)
    let weekday = calendar.component(.weekday, from: today) // 1 = Sunday … 7 = Saturday
    let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
    let d = calendar.date(byAdding: .day, value: offsetFromMonday, to: monday)!
    return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: d)!
}

func todayAt(_ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)!
}

var skipped: [String] = []

do {
    let db = try AppDatabase.open(at: paths.database)
    let workspace = try db.ensureDefaultWorkspace()
    let frontbot = try db.ensureDefaultAgent(workspaceId: workspace.id)
    // El agente por defecto se crea con la descripción en español; la demo es en inglés.
    var frontbotDraft = AgentDraft(agent: frontbot)
    frontbotDraft.description = "Brands, social media, tasks and business ideas."
    _ = try db.updateAgent(id: frontbot.id, draft: frontbotDraft)
    let brandFiles = BrandFiles(paths: paths)
    let library = SkillLibrary(db: db, paths: paths)

    // MARK: 1. Brands
    let cafe = try db.createBrand(workspaceId: workspace.id, name: "Café Sol", industry: "Specialty coffee shop",
                                  networks: [.instagram, .linkedin])
    try brandFiles.writeGuide(brandId: cafe.id, markdown: """
        # Café Sol

        ## Voice
        Warm, playful, never salesy.

        ## Topics
        Specialty coffee · Baristas · The neighborhood

        ## Audience
        Remote workers who love a good flat white.
        """)
    let northwind = try db.createBrand(workspaceId: workspace.id, name: "Northwind Studio", industry: "Design studio",
                                       networks: [.linkedin])
    try brandFiles.writeGuide(brandId: northwind.id, markdown: """
        # Northwind Studio

        ## Voice
        Clear, confident, quietly witty.

        ## Topics
        Brand identity · Product design · Case studies

        ## Audience
        Founders and marketing leads at early-stage startups.
        """)

    // MARK: 2. Posts (current week)
    _ = try db.createDraft(brandId: cafe.id, network: .instagram,
                           body: "Behind the bar: meet Ana, our roaster. Six years roasting, one rule: if it isn't good enough for her, it isn't good enough for you. ☕",
                           media: [], scheduledFor: day(0, 10))
    _ = try db.createDraft(brandId: cafe.id, network: .instagram,
                           body: "Latte art in 15 seconds — watch Ana pour a rosetta.", media: [], scheduledFor: day(2, 12))
    let thu = try db.createDraft(brandId: cafe.id, network: .linkedin,
                                 body: "Why we roast in-house: fresher beans, fairer prices for growers, and better coffee for you.",
                                 media: [], scheduledFor: day(3, 9, 30))
    _ = try db.transitionPost(id: thu.id, to: .approved, actor: .user)
    _ = try db.createDraft(brandId: cafe.id, network: .instagram,
                           body: "Weekend brunch carousel: 5 plates that pair perfectly with a flat white.", media: [], scheduledFor: day(4, 11))
    _ = try db.createDraft(brandId: northwind.id, network: .linkedin,
                           body: "Case study: how we rebuilt a fintech brand in six weeks — and what we'd do differently.",
                           media: [], scheduledFor: day(1, 9))

    // MARK: 3. Agents
    let copywriter = try db.createAgent(workspaceId: workspace.id, draft: AgentDraft(
        name: "Copywriter", icon: "pencil.and.scribble",
        description: "Writes captions and hooks in each brand's voice",
        instructions: "Write short, warm captions. Lead with a hook in the first line. Follow the brand guide; never invent prices or promos.",
        model: "claude-sonnet-5-5"), status: .active)
    _ = try db.createAgent(workspaceId: workspace.id, draft: AgentDraft(
        name: "Researcher", icon: "magnifyingglass",
        description: "Finds trends, competitors and opportunities",
        instructions: "Research trends, competitors and opportunities for each brand. Cite your sources and separate facts from opinions.",
        model: "claude-opus-5-5"), status: .active)
    let community = try db.createAgent(workspaceId: workspace.id, draft: AgentDraft(
        name: "Community Manager", icon: "calendar",
        description: "Plans the week and keeps the calendar full",
        instructions: "Plan each brand's week, keep the calendar full and leave every post as a draft for review.",
        model: "claude-sonnet-5-5"), status: .active)

    // MARK: 4. Skills
    let skills: [(String, String, String)] = [
        ("brand-voice", "Write in each brand's voice using its guide",
         """
         # Brand voice

         1. Read the brand guide before writing anything.
         2. Match the Voice section: word choice, energy, humor.
         3. Talk to the Audience described in the guide, not to everyone.
         4. Never invent prices, promos or facts that aren't in the guide.
         """),
        ("hook-writing", "Open every caption with a hook that stops the scroll",
         """
         # Hook writing

         - The first line must work on its own: a question, a surprising fact or a tiny story.
         - Keep it under 12 words.
         - Put the brand name later, never first.
         - Write 3 options and keep the strongest.
         """),
        ("linkedin-format", "Format posts for LinkedIn: short lines, one idea, a clear ending",
         """
         # LinkedIn format

         - One idea per post.
         - Short lines with white space between them.
         - End with a question or a clear takeaway.
         - Max 3 hashtags, at the end.
         """),
    ]
    for (name, description, body) in skills {
        let skill = try library.createUserSkill(name: name, description: description, body: body)
        try library.assign(skillId: skill.id, to: copywriter.id)
    }

    // MARK: 5. Memory (oldest first so the list reads top-down)
    for note in ["Max 3 hashtags per post", "Café Sol's audience: remote workers",
                 "Posts on Tuesdays and Fridays", "Prefers a friendly, casual tone"] {
        _ = try db.remember(agentId: copywriter.id, text: note)
    }

    // MARK: 6. Lab
    var labSettings = try db.labSettings(agentId: copywriter.id)
    labSettings.enabled = true
    try db.saveLabSettings(labSettings)

    func runSession(_ topicId: String, start: Date, minutes: Double, tokens: Int, outcome: LabOutcome,
                    summary: String, conclusion: String? = nil) throws -> String {
        let s = try db.startLabSession(topicId: topicId, budgetTokens: 150_000, now: start)
        try db.finishLabSession(id: s.id, status: .done, outcome: outcome, summary: summary, conclusion: conclusion,
                                tokens: tokens, models: [LabModelUsage(model: "claude-sonnet-5-5", tokens: tokens)],
                                now: start.addingTimeInterval(minutes * 60))
        return s.id
    }

    // Earlier, already learned topic.
    let learned = try db.openTopic(agentId: copywriter.id, question: "Best time to post on LinkedIn",
                                   why: "Café Sol and Northwind both post on LinkedIn; timing could lift reach without extra work.",
                                   origin: .agent, now: now.addingTimeInterval(-9 * 86_400))
    let l1 = try runSession(learned.id, start: now.addingTimeInterval(-9 * 86_400), minutes: 14, tokens: 38_400, outcome: .continue,
                            summary: "Collected posting times and reactions from past LinkedIn posts.")
    try db.addEntry(topicId: learned.id, sessionId: l1, kind: .hypothesis, text: "Weekday mornings beat afternoons on LinkedIn",
                    evidence: nil, sources: [], model: "claude-sonnet-5-5")
    let l2 = try runSession(learned.id, start: now.addingTimeInterval(-8 * 86_400), minutes: 11, tokens: 31_200, outcome: .resolve,
                            summary: "Compared morning vs afternoon posts across both brands.",
                            conclusion: "Tuesday–Thursday between 8:30 and 10:00 gets the most reach for both brands.")
    try db.addEntry(topicId: learned.id, sessionId: l2, kind: .result, text: "Morning posts got 1.6× the reactions of afternoon posts",
                    evidence: .medium, sources: [], model: "claude-sonnet-5-5")
    try db.addEntry(topicId: learned.id, sessionId: l2, kind: .conclusion,
                    text: "Tuesday–Thursday between 8:30 and 10:00 gets the most reach for both brands.",
                    evidence: .medium, sources: [], model: "claude-sonnet-5-5")

    // Open topic with a pending graduation proposal.
    let open = try db.openTopic(agentId: copywriter.id, question: "Which carousel cover performs best?",
                                why: "Carousels are Café Sol's most saved format; the cover decides whether people swipe.",
                                origin: .agent, now: now.addingTimeInterval(-3 * 86_400))
    let versions = SkillVersions(library: library)
    _ = try versions.propose(agentId: copywriter.id, topicId: open.id, kind: .new, skillName: "carousel-covers",
                             description: "How to design carousel covers that get saved",
                             body: """
                             # Carousel covers

                             - Put a real face on the cover whenever possible (Ana pouring beats a product shot).
                             - One short promise in large type: what the reader gets by swiping.
                             - High contrast; the first slide must read at thumbnail size.
                             - Keep the brand mark small, bottom corner.
                             """,
                             files: [:],
                             evidenceSummary: "Across past carousels from both brands, covers with a face got ~2× the saves of text-only or product-only covers. Strong, consistent evidence.")
    // `propose` closes the topic; reopen it so it shows as an open study with the proposal pending.
    try db.setTopicStatus(id: open.id, .studying, reason: nil, now: now.addingTimeInterval(-3 * 86_400))
    let s1 = try runSession(open.id, start: now.addingTimeInterval(-3 * 86_400), minutes: 12, tokens: 42_800, outcome: .continue,
                            summary: "Framed the question and listed past carousels by cover type.")
    try db.addEntry(topicId: open.id, sessionId: s1, kind: .hypothesis, text: "Covers with a face get more saves",
                    evidence: nil, sources: [], model: "claude-sonnet-5-5")
    let s2 = try runSession(open.id, start: now.addingTimeInterval(-2 * 86_400), minutes: 16, tokens: 51_300, outcome: .continue,
                            summary: "Compared saves per carousel by cover type.")
    try db.addEntry(topicId: open.id, sessionId: s2, kind: .test, text: "Compared past carousels by cover type",
                    evidence: nil, sources: [], model: "claude-sonnet-5-5")
    let s3 = try runSession(open.id, start: now.addingTimeInterval(-40 * 60), minutes: 10, tokens: 36_900, outcome: .continue,
                            summary: "Checked the pattern holds for both brands and drafted a skill.")
    try db.addEntry(topicId: open.id, sessionId: s3, kind: .result, text: "Strong — consistent across brands",
                    evidence: .strong, sources: [], model: "claude-sonnet-5-5")

    // MARK: 7. Folders & network (outside the data folder: the app refuses folders inside it)
    let filesRoot = URL(fileURLWithPath: paths.root.standardizedFileURL.path + " files", isDirectory: true)
    for name in ["Café Sol", "Northwind Studio"] {
        let folder = filesRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# \(name) — notes\n\n- Ideas for next week\n- Photos to caption\n".write(
            to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let real = try AgentFiles.validatedFolder(folder.path, protected: [paths.root])
        try db.addFolder(agentId: copywriter.id, path: real)
    }
    try db.setNetworkDomains(agentId: copywriter.id, ["cafesol.com", "github.com", "registry.npmjs.org"])

    // MARK: 8. Conversations (older ones first so the main one is the most recent)
    let history: [(Agent, Brand?, String, String)] = [
        (community, northwind, "Plan Northwind's LinkedIn for November",
         "Here's a 4-week plan: one case study, one process post and one team post per week. Saved as drafts."),
        (frontbot, cafe, "Ideas for a rainy-day promo",
         "Three ideas that stay on-brand without discounts: a cozy-corner Reel, a \"rainy day playlist\" story and a hot chocolate pour."),
        (copywriter, cafe, "Rewrite the brunch caption",
         "**Option 1:** Brunch is better with a flat white. Swipe for 5 plates we can't stop ordering."),
    ]
    for (agent, brand, prompt, reply) in history {
        let c = try db.createConversation(workspaceId: workspace.id, agentId: agent.id, brandId: brand?.id, firstPrompt: prompt)
        try db.appendMessage(conversationId: c.id, role: .user, text: prompt)
        try db.appendMessage(conversationId: c.id, role: .agent, text: reply)
    }
    let main = try db.createConversation(workspaceId: workspace.id, agentId: frontbot.id, brandId: cafe.id,
                                         firstPrompt: "Draft 3 posts for Café Sol this week")
    try db.appendMessage(conversationId: main.id, role: .user, text: "Draft 3 posts for Café Sol this week")
    try db.appendMessage(conversationId: main.id, role: .tool, text: "→ Read the Café Sol brand guide")
    try db.appendMessage(conversationId: main.id, role: .tool, text: "→ Created 3 drafts")
    try db.appendMessage(conversationId: main.id, role: .agent, text: """
        ### 3 posts for this week
        - **Mon** · Behind the bar: meet our roaster
        - **Wed** · Latte art in 15 seconds (Reel)
        - **Fri** · Weekend brunch carousel

        Saved as drafts in your calendar. Want me to add a LinkedIn post too?
        """)
    skipped.append("Conversation title \"Café Sol — posts this week\": no public API sets a title; it is derived from the first prompt (\"\(main.title)\").")

    // MARK: 9. Idea
    let idea = try db.createIdea(workspaceId: workspace.id, title: "Specialty coffee subscriptions for offices",
                                 summary: "Weekly deliveries of freshly roasted beans plus a monthly barista visit for small offices and coworking spaces.",
                                 sources: ["https://example.com/reports/office-coffee-market-2026",
                                           "https://example.com/blog/remote-teams-return-to-office",
                                           "https://example.com/surveys/coworking-perks"],
                                 score: 4)
    let report = try brandFiles.writeIdeaReport(ideaId: idea.id, markdown: """
        # Specialty coffee subscriptions for offices

        ## Opportunity
        Hybrid teams are back in the office 2–3 days a week and want better coffee than the pod machine.

        ## Offer
        - Weekly bean delivery, roasted in-house
        - Monthly barista visit and tasting
        - Three tiers by team size

        ## Risks
        - Delivery logistics outside the neighborhood
        - Competing with big office-supply contracts

        ## Verdict
        **4/5** — a natural extension of Café Sol's roastery with recurring revenue.
        """)
    try db.setIdeaReportPath(id: idea.id, path: report.path)

    // MARK: 10. Scheduled task
    _ = try db.createTask(agentId: community.id,
                          draft: TaskDraft(name: "Weekly content plan",
                                           instruction: "Plan next week's posts for every brand and leave them as drafts.",
                                           schedule: .weekly(days: [2], TimeOfDay(9, 0))),
                          status: .active, createdBy: nil)

    // MARK: 11. Today's tasks
    _ = try db.createTask(workspaceId: workspace.id, title: "Review Friday's posts", dueDate: todayAt(11), brandId: cafe.id)
    _ = try db.createTask(workspaceId: workspace.id, title: "Send brand guide to Ana", dueDate: todayAt(16), brandId: cafe.id)

    print("Seeded demo data into \(paths.root.path)")
    print("Agent folders: \(filesRoot.path)")
    if !skipped.isEmpty {
        print("Skipped:")
        skipped.forEach { print("  - \($0)") }
    }
} catch {
    fail("seeding failed: \(error)")
}
