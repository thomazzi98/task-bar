import AppKit
import SwiftUI
import TaskBarCore

/// Renders every screen of the popover to PNG files, filled with sample data.
///
/// Used to produce the README screenshots and to review layout changes without clicking
/// through the app. Nothing here touches the user's real tasks, notes or sessions.
@MainActor
enum SnapshotRenderer {
    private static let size = StatusItemController.panelSize

    private struct Scene {
        let name: String
        /// Shows notes rendered rather than as raw Markdown.
        var rendersNotes = false
        /// Scrolls the screen before capturing, for sections below the fold.
        var scroll: Scroll?
        let prepare: (AppEnvironment, DemoData) -> Void
    }

    private enum Scroll {
        /// The bottom of the screen.
        case end
        /// A distance in points from the top of the scrolling content.
        case offset(CGFloat)
    }

    private static let scenes: [Scene] = [
        Scene(name: "tasks") { environment, _ in
            environment.appState.select(.tasks)
        },
        Scene(name: "task-detail", rendersNotes: true) { environment, demo in
            environment.appState.select(.tasks)
            environment.tasks.open(demo.featuredTaskID)
        },
        Scene(name: "notes") { environment, _ in
            environment.tasks.goToRoot()
            environment.appState.select(.notes)
        },
        Scene(name: "prompt") { environment, demo in
            environment.appState.select(.notes)
            environment.notes.open(demo.promptNoteID)
        },
        Scene(name: "agents") { environment, _ in
            environment.notes.closeEditor()
            environment.usage.section = .sessions
            environment.appState.select(.agents)
        },
        Scene(name: "agent-detail") { environment, demo in
            environment.appState.select(.agents)
            environment.agents.select(demo.featuredSessionID)
        },
        Scene(name: "usage") { environment, _ in
            environment.agents.select(nil)
            environment.usage.section = .usage
            environment.appState.select(.agents)
        },
        Scene(name: "usage-projects", scroll: .offset(400)) { environment, _ in
            environment.usage.section = .usage
            environment.appState.select(.agents)
        },
        Scene(name: "ask") { environment, _ in
            environment.appState.select(.ask)
            environment.ask.applyPreview(messages: askConversation)
        },
        Scene(name: "calendar") { environment, _ in
            environment.agents.select(nil)
            environment.usage.section = .sessions
            environment.appState.select(.calendar)
        },
        Scene(name: "links") { environment, _ in
            environment.links.closeFolder()
            environment.appState.select(.links)
        },
        Scene(name: "links-folder") { environment, demo in
            environment.appState.select(.links)
            environment.links.open(demo.workFolderID)
        },
        Scene(name: "clipboard") { environment, _ in
            environment.appState.select(.clipboard)
        },
        Scene(name: "git") { environment, _ in
            environment.git.select(nil)
            environment.appState.select(.git)
        },
        Scene(name: "git-detail") { environment, demo in
            environment.appState.select(.git)
            environment.git.select(demo.paymentsRepoRoot)
        },
        Scene(name: "git-detail-prs", scroll: .end) { environment, demo in
            environment.appState.select(.git)
            environment.git.select(demo.paymentsRepoRoot)
        },
        Scene(name: "system") { environment, _ in
            environment.appState.select(.system)
        },
        Scene(name: "system-ports", scroll: .end) { environment, _ in
            environment.appState.select(.system)
        },
        Scene(name: "settings") { environment, _ in
            environment.appState.isShowingSettings = true
        }
    ]

    /// A sample Ask conversation with proposed actions. Nothing here reads the real machine.
    private static let askConversation: [AskMessage] = [
        AskMessage(role: .user, text: "Why is my CPU so high?"),
        AskMessage(
            role: .assistant,
            text: "Six `yes` processes are each using about 90% of a core, which is most of the machine's CPU. "
                + "They do no useful work, so they can be stopped.\n\n"
                + "- Quit the two with the highest CPU first and check whether the load drops.\n"
                + "- Nothing else in the snapshot is busy.",
            actions: [
                AskAction(proposal: .quit(pid: 4011, name: "yes")),
                AskAction(proposal: .quit(pid: 4012, name: "yes"))
            ]
        )
    ]

    /// Renders all scenes in light and dark appearance, plus a combined banner for each.
    static func renderAll(into directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []

        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("taskbar-snapshots-\(UUID().uuidString)", isDirectory: true)
            let suiteName = "taskbar.snapshots.\(UUID().uuidString)"
            defer {
                try? FileManager.default.removeItem(at: scratch)
                UserDefaults.standard.removePersistentDomain(forName: suiteName)
            }

            let paths = AppPaths(
                supportDirectory: scratch.appendingPathComponent("support", isDirectory: true),
                claudeDirectory: scratch.appendingPathComponent("claude", isDirectory: true)
            )
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            // Links and Clipboard read their files when the app starts, so they are seeded first.
            let workFolderID = try DemoData.writeStores(to: paths)
            let environment = AppEnvironment(paths: paths, defaults: defaults)
            let demo = DemoData.install(in: environment, workFolderID: workFolderID)

            var images: [String: NSImage] = [:]
            for scene in scenes {
                defaults.set(scene.rendersNotes, forKey: "editor.opensInPreview")
                scene.prepare(environment, demo)
                let image = try render(environment.rootView(), appearance: appearanceName, scroll: scene.scroll)
                images[scene.name] = image
                let url = directory.appendingPathComponent("\(scene.name)-\(suffix).png")
                try write(image, to: url)
                written.append(url)
            }

            let banner = composeBanner(
                [images["task-detail"], images["usage"], images["system"]].compactMap { $0 },
                isDark: suffix == "dark"
            )
            let bannerURL = directory.appendingPathComponent("banner-\(suffix).png")
            try write(banner, to: bannerURL)
            written.append(bannerURL)
        }
        return written
    }

    /// Renders the screens that read live data (System, Agents › Usage, Git, Links, Clipboard)
    /// from this Mac, to check them without opening the popover.
    ///
    /// The environment runs on a scratch support folder, so starting it never writes to the
    /// running app's data, such as the hook spool's PID file that hook events are routed by. The
    /// user's Links and Clipboard files are copied into the scratch folder so those screens show
    /// real content. The copies are read from the originals and never written back. The scratch
    /// folder is deleted before this returns.
    static func renderLive(into directory: URL, settle: Duration = .seconds(12)) async throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let live = AppPaths.live()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskbar-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let support = scratch.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        for original in [live.linksFile, live.clipboardFile] where FileManager.default.fileExists(atPath: original.path) {
            try FileManager.default.copyItem(at: original, to: support.appendingPathComponent(original.lastPathComponent))
        }
        let paths = AppPaths(supportDirectory: support, claudeDirectory: live.claudeDirectory)

        let suiteName = "taskbar.live-snapshots.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let environment = AppEnvironment(paths: paths, defaults: defaults)
        environment.agents.start()
        defer { environment.agents.stop() }
        environment.appState.isPanelVisible = true
        environment.system.setPanelVisible(true)

        // Each scene may also switch its screen's background work on and off around the shot.
        let scenes: [(name: String, tab: AppTab, show: ((Bool) -> Void)?)] = [
            ("live-system", .system, { visible in
                environment.system.setDetailVisible(visible)
                environment.peripherals.setVisible(visible)
                environment.ports.setVisible(visible)
            }),
            ("live-usage", .agents, { visible in
                environment.usage.section = visible ? .usage : .sessions
                environment.usage.setVisible(visible)
            }),
            ("live-git", .git, { environment.git.setVisible($0) }),
            ("live-links", .links, nil),
            ("live-clipboard", .clipboard, nil)
        ]

        var written: [URL] = []
        for scene in scenes {
            environment.appState.select(scene.tab)
            scene.show?(true)
            // Sleeping, not spinning the run loop, lets the view models' main-actor tasks run.
            try await Task.sleep(for: settle)
            let image = try render(environment.rootView(), appearance: .aqua)
            scene.show?(false)
            let url = directory.appendingPathComponent("\(scene.name).png")
            try write(image, to: url)
            written.append(url)
        }
        return written
    }

    // MARK: Rendering

    private static func render(_ view: some View, appearance: NSAppearance.Name, scroll: Scroll? = nil) throws -> NSImage {
        let shape = RoundedRectangle(cornerRadius: PopoverPanel.cornerRadius, style: .continuous)
        let content = view
            .frame(width: size.width, height: size.height)
            // The live popover sits on a translucent material; use the window colour here.
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(shape)

        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.layoutIfNeeded()

        // Give SwiftUI a few turns of the run loop to lay out lists and apply state changes.
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        hosting.layoutSubtreeIfNeeded()

        if let scroll, let scrollView = firstSubview(of: NSScrollView.self, in: hosting) {
            let clip = scrollView.contentView
            let lowest = max((scrollView.documentView?.frame.height ?? 0) - clip.bounds.height, 0)
            let target: CGFloat
            switch scroll {
            case .end: target = lowest
            case .offset(let distance): target = min(distance, lowest)
            }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
            scrollView.reflectScrolledClipView(clip)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            hosting.layoutSubtreeIfNeeded()
        }

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        window.contentView = nil

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    /// The first view of the given type in the tree, depth first. Used to reach the scroll view
    /// behind a SwiftUI `ScrollView`.
    private static func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    /// Lays several screens side by side on a soft gradient, for the top of the README.
    private static func composeBanner(_ panels: [NSImage], isDark: Bool) -> NSImage {
        let margin: CGFloat = 44
        let spacing: CGFloat = 28
        let width = margin * 2 + CGFloat(panels.count) * size.width + CGFloat(max(panels.count - 1, 0)) * spacing
        let height = margin * 2 + size.height
        let canvas = NSSize(width: width, height: height)

        return NSImage(size: canvas, flipped: false) { rect in
            let colors = isDark
                ? [NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.16, alpha: 1), NSColor(calibratedRed: 0.17, green: 0.13, blue: 0.24, alpha: 1)]
                : [NSColor(calibratedRed: 0.89, green: 0.92, blue: 0.99, alpha: 1), NSColor(calibratedRed: 0.96, green: 0.90, blue: 0.98, alpha: 1)]
            NSGradient(colors: colors)?.draw(in: rect, angle: -35)

            for (index, panel) in panels.enumerated() {
                let origin = NSPoint(x: margin + CGFloat(index) * (size.width + spacing), y: margin)
                let frame = NSRect(origin: origin, size: size)

                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.55 : 0.22)
                shadow.shadowBlurRadius = 26
                shadow.shadowOffset = NSSize(width: 0, height: -10)
                shadow.set()
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(roundedRect: frame, xRadius: PopoverPanel.cornerRadius, yRadius: PopoverPanel.cornerRadius).fill()
                NSGraphicsContext.restoreGraphicsState()

                panel.draw(in: frame)
            }
            return true
        }
    }

    private static func write(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
    }
}

/// Believable sample content for snapshots.
@MainActor
struct DemoData {
    let featuredTaskID: UUID
    let promptNoteID: UUID
    let featuredSessionID: String
    /// The "Work" folder of the Links tab.
    let workFolderID: UUID
    /// The repository the Git detail scene opens.
    let paymentsRepoRoot: String

    /// Writes the Links and Clipboard documents into the scratch support directory. Returns the
    /// ID of the "Work" folder. Must run before `AppEnvironment` is created, since both models
    /// read their files in `init`.
    static func writeStores(to paths: AppPaths, now: Date = Date()) throws -> UUID {
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        let minute: TimeInterval = 60
        let hour: TimeInterval = 3_600
        let day: TimeInterval = 86_400

        let work = LinkFolder(name: "Work", colorName: "blue", symbol: "briefcase", links: [
            LinkItem(title: "GitHub", url: "https://github.com/acme/payments-api", createdAt: ago(2 * day)),
            LinkItem(title: "Linear", url: "https://linear.app/acme/team/PAY/active", createdAt: ago(2 * day)),
            LinkItem(title: "Vercel", url: "https://vercel.com/acme/web-dashboard", createdAt: ago(day)),
            LinkItem(title: "Figma", url: "https://www.figma.com/file/8sKq2Dd7wQ0/Onboarding", createdAt: ago(day)),
            LinkItem(title: "Sentry", url: "https://acme.sentry.io/issues/", createdAt: ago(5 * hour)),
            LinkItem(title: "Notion", url: "https://www.notion.so/acme/Team-Wiki", createdAt: ago(3 * day))
        ])
        let folders = [
            work,
            LinkFolder(name: "Docs", colorName: "purple", symbol: "book", links: [
                LinkItem(title: "Swift Language Guide", url: "https://docs.swift.org/swift-book/"),
                LinkItem(title: "SwiftUI", url: "https://developer.apple.com/documentation/swiftui"),
                LinkItem(title: "MDN Web Docs", url: "https://developer.mozilla.org/"),
                LinkItem(title: "PostgreSQL manual", url: "https://www.postgresql.org/docs/17/")
            ]),
            LinkFolder(name: "Design", colorName: "orange", symbol: "globe", links: [
                LinkItem(title: "Dribbble", url: "https://dribbble.com/"),
                LinkItem(title: "Refactoring UI", url: "https://www.refactoringui.com/"),
                LinkItem(title: "Heroicons", url: "https://heroicons.com/")
            ]),
            LinkFolder(name: "Learning", colorName: "green", symbol: "graduationcap", links: [
                LinkItem(title: "Advent of Code", url: "https://adventofcode.com/"),
                LinkItem(title: "Exercism Swift", url: "https://exercism.org/tracks/swift"),
                LinkItem(title: "Rust by Example", url: "https://doc.rust-lang.org/rust-by-example/")
            ]),
            LinkFolder(name: "Reading", colorName: "teal", symbol: "star", links: [
                LinkItem(title: "Simon Willison's weblog", url: "https://simonwillison.net/"),
                LinkItem(title: "Paul Graham essays", url: "https://paulgraham.com/articles.html"),
                LinkItem(title: "Hacker News", url: "https://news.ycombinator.com/")
            ])
        ]
        try JSONFileStore<LinksDocument>(url: paths.linksFile).save(LinksDocument(folders: folders))

        let clips = [
            ClipboardItem(
                text: "ssh -i ~/.ssh/id_work deploy@staging.example.com",
                copiedAt: ago(2 * day), isPinned: true
            ),
            ClipboardItem(
                text: "Alex Morgan\nStaff Engineer, Acme\nalex@example.com",
                copiedAt: ago(4 * day), isPinned: true
            ),
            ClipboardItem(text: "https://github.com/acme/payments-api/pull/214", copiedAt: ago(12 * minute)),
            ClipboardItem(
                text: "func charge(_ amount: Int, key: String) async throws -> Charge {\n    try await gateway.create(amount: amount, idempotencyKey: key)\n}",
                copiedAt: ago(40 * minute)
            ),
            ClipboardItem(text: "#1F6FEB", copiedAt: ago(2 * hour)),
            ClipboardItem(text: "git rebase -i HEAD~3", copiedAt: ago(5 * hour)),
            ClipboardItem(text: "Remember to rotate the staging API key before Friday.", copiedAt: ago(day)),
            ClipboardItem(text: "SELECT id, status FROM charges WHERE idempotency_key = $1;", copiedAt: ago(day + 4 * hour)),
            ClipboardItem(text: "~/Documents/workspaces/payments-api/.env.example", copiedAt: ago(2 * day)),
            ClipboardItem(text: "Thanks for the quick turnaround, I will review the draft tonight.", copiedAt: ago(3 * day))
        ]
        try JSONFileStore<ClipboardDocument>(url: paths.clipboardFile).save(ClipboardDocument(items: clips))
        return work.id
    }

    static func install(in environment: AppEnvironment, workFolderID: UUID, now: Date = Date()) -> DemoData {
        let featured = installTasks(in: environment.tasks)
        let promptID = installNotes(in: environment.notes)
        let sessionID = installAgents(in: environment.agents, now: now)
        installAgenda(in: environment.agenda, now: now)
        installSystem(in: environment.system)
        installDevicesAndPorts(peripherals: environment.peripherals, ports: environment.ports)
        installUsage(in: environment.usage, now: now)
        let paymentsRoot = installGit(in: environment.git, now: now)
        return DemoData(
            featuredTaskID: featured,
            promptNoteID: promptID,
            featuredSessionID: sessionID,
            workFolderID: workFolderID,
            paymentsRepoRoot: paymentsRoot
        )
    }

    private static func installDevicesAndPorts(peripherals: PeripheralsViewModel, ports: PortsViewModel) {
        let gigabyte: UInt64 = 1_000_000_000
        let devices = [
            PeripheralDevice(name: "Magic Keyboard", kind: .keyboard, level: 82),
            PeripheralDevice(name: "MX Master 3S", kind: .mouse, level: 47),
            PeripheralDevice(name: "AirPods Pro", kind: .headphones, leftLevel: 90, rightLevel: 85, caseLevel: 60)
        ]
        let volumes = [
            MountedVolume(
                url: URL(fileURLWithPath: "/"), name: "Macintosh HD", formatName: "APFS",
                totalBytes: 994 * gigabyte, availableBytes: 412 * gigabyte, isRoot: true
            ),
            MountedVolume(
                url: URL(fileURLWithPath: "/Volumes/SanDisk 64GB"), name: "SanDisk 64GB", formatName: "exFAT",
                totalBytes: 64 * gigabyte, availableBytes: 21 * gigabyte,
                isRemovable: true, isEjectable: true, isInternal: false
            )
        ]
        peripherals.applyPreview(devices: devices, volumes: volumes)

        let user = NSUserName()
        let uid = getuid()
        let listening = [
            ListeningPort(pid: 41_207, command: "node", user: user, userID: uid, port: 3000, address: "*", isLoopbackOnly: false),
            ListeningPort(pid: 41_233, command: "node", user: user, userID: uid, port: 5173, address: "127.0.0.1", isLoopbackOnly: true),
            ListeningPort(pid: 812, command: "postgres", user: user, userID: uid, port: 5432, address: "127.0.0.1", isLoopbackOnly: true),
            ListeningPort(pid: 690, command: "redis-server", user: user, userID: uid, port: 6379, address: "127.0.0.1", isLoopbackOnly: true),
            ListeningPort(pid: 41_290, command: "node", user: user, userID: uid, port: 9229, address: "127.0.0.1", isLoopbackOnly: true)
        ]
        ports.applyPreview(ports: listening)
    }

    /// Seven days of Claude Code usage across three models and four projects. Built through the
    /// real aggregation, so the totals, costs and bars are computed the same way as in the app.
    private static func installUsage(in usage: UsageViewModel, now: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let models = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        let projects = ["payments-api", "web-dashboard", "task-bar", "infra"]
        // Relative activity per day, oldest first.
        let activity: [Double] = [0.6, 0.9, 1.4, 1.1, 1.7, 0.5, 1.2]
        // Opus does most of the work, Sonnet some, Haiku the small jobs.
        let modelPattern = [0, 0, 1, 0, 2, 0, 1, 0]

        var records: [UsageRecord] = []
        for (dayIndex, factor) in activity.enumerated() {
            let day = calendar.date(byAdding: .day, value: dayIndex - 6, to: today) ?? today
            for slot in 0..<8 {
                var stamp = calendar.date(byAdding: .hour, value: 9 + slot, to: day) ?? day
                if stamp > now { stamp = now.addingTimeInterval(-600) }
                let scale = factor * (1 + 0.15 * Double(slot % 3))
                records.append(UsageRecord(
                    messageID: "day\(dayIndex)-\(slot)",
                    model: models[modelPattern[slot]],
                    timestamp: stamp,
                    project: projects[(slot + dayIndex) % projects.count],
                    sessionID: "session-\(dayIndex)-\((slot + dayIndex) % 4)",
                    usage: TokenUsage(
                        input: Int(42_000 * scale),
                        output: Int(9_000 * scale),
                        cacheWrite: Int(65_000 * scale),
                        cacheRead: Int(1_100_000 * scale)
                    )
                ))
            }
        }
        usage.applyPreview(UsageReport.make(records: records, period: .week, now: now, calendar: calendar))
    }

    /// Three repositories: one with changes ahead of its remote, one clean, one behind. The
    /// payments repository also gets commits, branches and pull requests for the detail scene.
    /// Returns its root.
    private static func installGit(in git: GitViewModel, now: Date) -> String {
        let paymentsRoot = "/Users/dev/work/payments-api"
        let payments = GitRepoSnapshot(
            root: paymentsRoot,
            status: GitRepoStatus(
                branch: "feature/idempotency",
                upstream: "origin/feature/idempotency",
                ahead: 2,
                stagedCount: 1,
                modifiedCount: 1,
                untrackedCount: 1,
                totalChanges: 3,
                changes: [
                    GitChange(path: "Sources/Charges/ChargeService.swift", kind: .added, isStaged: true),
                    GitChange(path: "Sources/Charges/ChargeController.swift", kind: .modified, isStaged: false),
                    GitChange(path: "Migrations/0042_idempotency_keys.sql", kind: .untracked, isStaged: false)
                ]
            ),
            commits: [
                GitCommit(
                    hash: "4c8e0d1f7a2b9c3e5d6f8a1b2c3d4e5f60718293", shortHash: "4c8e0d1", author: "Ana Lima",
                    relativeDate: "25 minutes ago", subject: "Return the original charge on retried requests"
                ),
                GitCommit(
                    hash: "7a19b3e2c4d5f60718293a4b5c6d7e8f90a1b2c3", shortHash: "7a19b3e", author: "Ana Lima",
                    relativeDate: "1 hour ago", subject: "Add idempotency_key column to charges"
                ),
                GitCommit(
                    hash: "e41d0c9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e", shortHash: "e41d0c9", author: "Rafael Souza",
                    relativeDate: "yesterday", subject: "Extract ChargeService from the checkout controller"
                ),
                GitCommit(
                    hash: "2b7f5a8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6", shortHash: "2b7f5a8", author: "Rafael Souza",
                    relativeDate: "3 days ago", subject: "Bump the payment gateway SDK to 4.2"
                )
            ],
            branches: [
                GitBranch(name: "feature/idempotency", relativeDate: "25 minutes ago", ahead: 2),
                GitBranch(name: "main", relativeDate: "2 days ago")
            ],
            pullRequests: [
                GitPullRequest(
                    number: 214, title: "Add idempotency keys to the charge endpoint",
                    headBranch: "feature/idempotency", url: "https://github.com/acme/payments-api/pull/214",
                    isDraft: false, authorLogin: "ana-lima", reviewDecision: .reviewRequired
                ),
                GitPullRequest(
                    number: 211, title: "Retry failed webhook deliveries with backoff",
                    headBranch: "fix/webhook-retry", url: "https://github.com/acme/payments-api/pull/211",
                    isDraft: true, authorLogin: "dev-kim"
                )
            ]
        )
        let dashboard = GitRepoSnapshot(
            root: "/Users/dev/work/web-dashboard",
            status: GitRepoStatus(branch: "main", upstream: "origin/main"),
            commits: [
                GitCommit(
                    hash: "f0c3a7d9e8b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5", shortHash: "f0c3a7d", author: "Dev Kim",
                    relativeDate: "3 hours ago", subject: "Add dark mode to the usage chart"
                )
            ]
        )
        let infra = GitRepoSnapshot(
            root: "/Users/dev/work/infra",
            status: GitRepoStatus(
                branch: "main",
                upstream: "origin/main",
                behind: 1,
                modifiedCount: 1,
                totalChanges: 1,
                changes: [GitChange(path: "terraform/staging/main.tf", kind: .modified, isStaged: false)]
            )
        )
        git.applyPreview(snapshots: [payments, dashboard, infra])
        return paymentsRoot
    }

    private static func installTasks(in tasks: TasksViewModel) -> UUID {
        let launchNotes = """
        ## Goal
        Public beta on **March 3**. Keep the scope tight.

        - [x] Freeze the feature list
        - [ ] Final pass on onboarding copy
        - [ ] Confirm pricing with finance

        Spec: [beta-plan.md](https://example.com/beta-plan)
        """
        let launch = TaskItem(
            title: "Launch the public beta #release",
            notes: launchNotes,
            priority: .high,
            children: [
                TaskItem(title: "Finish the onboarding flow", isDone: true, completedAt: Date()),
                TaskItem(title: "Fix the crash on cold start", notes: "Only on macOS 14.", priority: .high, children: [
                    TaskItem(title: "Reproduce with a clean profile", isDone: true),
                    TaskItem(title: "Add a regression test")
                ]),
                TaskItem(title: "Write the release notes"),
                TaskItem(title: "Record a 60-second demo #marketing")
            ]
        )
        tasks.insert(TaskItem(title: "Renew the domain names", priority: .low))
        tasks.insert(TaskItem(title: "Book flights for the conference #travel"))
        tasks.insert(TaskItem(title: "Review open pull requests", children: [
            TaskItem(title: "Auth middleware refactor", isDone: true),
            TaskItem(title: "Dashboard dark mode"),
            TaskItem(title: "Bump dependencies")
        ]))
        tasks.insert(TaskItem(title: "Prepare the Q1 planning deck #work", notes: "Outline first.", priority: .medium))
        tasks.insert(launch)
        tasks.insert(TaskItem(title: "Pay the cloud invoice", isDone: true, completedAt: Date()))
        return launch.id
    }

    private static func installNotes(in notes: NotesViewModel) -> UUID {
        let prompt = Note(
            title: "Refactor the billing module",
            body: """
            Refactor the billing module so every charge goes through a single, well-tested service.

            ## Context
            - Charges are created in three places today: checkout, renewals and the admin panel.
            - Each one talks to the payment provider directly.

            ## Requirements
            - Introduce a `ChargeService` with one public entry point.
            - Make charge creation idempotent using a client-supplied key.
            - Keep the public API responses unchanged.

            ## Expected output
            - The refactor in small commits, plus unit tests for the new service.
            """,
            kind: .prompt,
            updatedAt: Date().addingTimeInterval(-9 * 60)
        )
        let now = Date()
        notes.insert(Note(
            title: "Books to read",
            body: "- The Pragmatic Programmer\n- Designing Data-Intensive Applications",
            updatedAt: now.addingTimeInterval(-3 * 86_400)
        ))
        notes.insert(Note(
            title: "1:1 with Ana",
            body: "Talked about the roadmap and hiring.\n\n- [ ] Share the Q1 draft\n- [ ] Intro to the design team",
            updatedAt: now.addingTimeInterval(-5 * 3_600)
        ))
        notes.insert(prompt)
        notes.insert(Note(
            title: "Product ideas",
            body: "Voice notes that turn into tasks.\nA weekly digest of what the agents shipped.",
            isPinned: true,
            updatedAt: now.addingTimeInterval(-26 * 3_600)
        ))
        return prompt.id
    }

    private static func installAgents(in agents: AgentsViewModel, now: Date) -> String {
        let blocked = AgentSession(
            id: "demo-payments",
            pid: 0,
            cwd: "/Users/dev/work/payments-api",
            entrypoint: "cli",
            title: "Add idempotency keys to the charge endpoint",
            status: .needsApproval,
            statusDetail: "Bash: Run the database migration",
            lastPrompt: "make charge creation idempotent",
            gitBranch: "feature/idempotency",
            model: "claude-opus-5-5",
            lastActivity: now.addingTimeInterval(-40),
            entries: [
                TranscriptEntry(id: "1", kind: .userPrompt, text: "Make charge creation idempotent using a client-supplied key."),
                TranscriptEntry(id: "2", kind: .assistantText, text: "I'll add an `idempotency_key` column, enforce uniqueness per customer, and return the original charge on a retry."),
                TranscriptEntry(id: "3", kind: .toolUse(name: "Read"), text: "ChargeController.swift"),
                TranscriptEntry(id: "4", kind: .toolUse(name: "Edit"), text: "ChargeService.swift"),
                TranscriptEntry(id: "5", kind: .assistantText, text: "The service is in place. Next I need to apply the schema change before running the tests."),
                TranscriptEntry(id: "6", kind: .toolUse(name: "Bash"), text: "Run the database migration")
            ]
        )
        agents.apply([
            blocked,
            AgentSession(
                id: "demo-dashboard", pid: 0, cwd: "/Users/dev/work/web-dashboard", entrypoint: "claude-vscode",
                title: "Build the usage chart", status: .working, statusDetail: "Edit: UsageChart.tsx",
                gitBranch: "main", lastActivity: now.addingTimeInterval(-4)
            ),
            AgentSession(
                id: "demo-taskbar", pid: 0, cwd: "/Users/dev/oss/task-bar", entrypoint: "cli",
                title: "Write unit tests for the transcript parser", status: .finished,
                gitBranch: "tests/parser", lastActivity: now.addingTimeInterval(-190)
            ),
            AgentSession(
                id: "demo-infra", pid: 0, cwd: "/Users/dev/work/infra", entrypoint: "cli",
                title: "Explain the staging Terraform layout", status: .idle,
                lastActivity: now.addingTimeInterval(-3_400)
            )
        ])
        return blocked.id
    }

    private static func installAgenda(in agenda: AgendaViewModel, now: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        func at(_ day: Date, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        let standupStart = now.addingTimeInterval(12 * 60)

        agenda.apply(events: [
            AgendaEvent(
                id: "standup", title: "Daily standup", start: standupStart, end: standupStart.addingTimeInterval(15 * 60),
                calendarName: "Work", calendarColorHex: "#4285F4",
                meetingURL: URL(string: "https://meet.google.com/abc-defg-hij")
            ),
            AgendaEvent(
                id: "review", title: "Design review: onboarding", start: standupStart.addingTimeInterval(2 * 3600),
                end: standupStart.addingTimeInterval(3 * 3600), calendarName: "Work", calendarColorHex: "#4285F4",
                meetingURL: URL(string: "https://zoom.us/j/123456789")
            ),
            AgendaEvent(
                id: "dentist", title: "Dentist", start: standupStart.addingTimeInterval(5 * 3600),
                end: standupStart.addingTimeInterval(6 * 3600), calendarName: "Personal", calendarColorHex: "#0B8043",
                location: "Main St. Clinic"
            ),
            AgendaEvent(
                id: "birthday", title: "Marina's birthday", start: tomorrow, end: tomorrow.addingTimeInterval(86_400),
                isAllDay: true, calendarName: "Birthdays", calendarColorHex: "#F4511E"
            ),
            AgendaEvent(
                id: "planning", title: "Sprint planning", start: at(tomorrow, 10), end: at(tomorrow, 11, 30),
                calendarName: "Work", calendarColorHex: "#4285F4",
                meetingURL: URL(string: "https://meet.google.com/xyz-uvwx-rst")
            ),
            AgendaEvent(
                id: "lunch", title: "Lunch with Carla", start: at(tomorrow, 12, 30), end: at(tomorrow, 13, 30),
                calendarName: "Personal", calendarColorHex: "#0B8043", location: "Café Central"
            )
        ], now: now, access: .granted)
    }

    private static func installSystem(in system: SystemViewModel) {
        let gigabyte: UInt64 = 1_073_741_824
        let megabyte: UInt64 = 1_048_576
        let snapshot = SystemSnapshot(
            cpu: CPULoad(overall: 0.34, perCore: [0.62, 0.48, 0.41, 0.55, 0.22, 0.18, 0.31, 0.12, 0.27, 0.09]),
            memory: MemoryUsage(
                totalBytes: 32 * gigabyte, appBytes: 13 * gigabyte, wiredBytes: 3 * gigabyte,
                compressedBytes: 2 * gigabyte, cachedBytes: 9 * gigabyte, swapUsedBytes: 0, pressure: .normal
            ),
            disk: DiskUsage(totalBytes: 994 * gigabyte, availableBytes: 412 * gigabyte),
            battery: BatteryStatus(percent: 82, isCharging: false, isOnACPower: false, minutesRemaining: 312),
            network: NetworkRate(bytesInPerSecond: 2_400_000, bytesOutPerSecond: 310_000),
            uptime: 273_600
        )
        // A gentle wave so the sparkline has some shape.
        let history: [Double] = (0..<40).map { index -> Double in
            let phase = Double(index)
            let slow: Double = 0.16 * sin(phase / 3.2)
            let fast: Double = 0.08 * cos(phase / 1.3)
            return 0.3 + slow + fast
        }

        func app(_ pid: Int32, _ name: String, bundleID: String, cpu: Double, memory: UInt64) -> RunningAppUsage {
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
            return RunningAppUsage(
                pid: pid, name: name, bundleIdentifier: bundleID, icon: icon,
                usage: ProcessGroupUsage(cpuPercent: cpu, memoryBytes: memory, processCount: 1)
            )
        }
        func process(_ pid: Int32, _ name: String, cpu: Double, memory: UInt64) -> ProcessUsage {
            ProcessUsage(pid: pid, parentPID: 1, userID: getuid(), name: name, cpuPercent: cpu, memoryBytes: memory)
        }

        // Built as separately typed constants: one large literal overwhelms the type checker.
        let megabytes: (UInt64) -> UInt64 = { $0 * megabyte }
        let apps: [RunningAppUsage] = [
            app(501, "Safari", bundleID: "com.apple.Safari", cpu: 12, memory: megabytes(3_400)),
            app(502, "Xcode", bundleID: "com.apple.dt.Xcode", cpu: 41, memory: megabytes(2_900)),
            app(503, "Terminal", bundleID: "com.apple.Terminal", cpu: 3, memory: megabytes(620)),
            app(504, "Mail", bundleID: "com.apple.mail", cpu: 0, memory: megabytes(410)),
            app(505, "Music", bundleID: "com.apple.Music", cpu: 2, memory: megabytes(280)),
            app(506, "Notes", bundleID: "com.apple.Notes", cpu: 0, memory: megabytes(190))
        ]
        let processes: [ProcessUsage] = [
            process(812, "swift-frontend", cpu: 96, memory: megabytes(1_200)),
            process(640, "node", cpu: 38, memory: megabytes(840)),
            process(377, "WindowServer", cpu: 11, memory: megabytes(520))
        ]
        let api = DockerContainer(
            id: "c1", names: ["/shop-api-1"], image: "shop/api:latest", state: "running", status: "Up 3 hours",
            ports: [DockerPort(privatePort: 8080, publicPort: 8080, type: "tcp")],
            labels: ["com.docker.compose.project": "shop"]
        )
        let database = DockerContainer(
            id: "c2", names: ["/shop-db-1"], image: "postgres:17", state: "running", status: "Up 3 hours",
            ports: [DockerPort(privatePort: 5432, publicPort: 5432, type: "tcp")],
            labels: ["com.docker.compose.project": "shop"]
        )
        let cache = DockerContainer(
            id: "c3", names: ["/redis"], image: "redis:7", state: "exited", status: "Exited (0) 2 days ago"
        )
        let containerLimit: UInt64 = 8 * gigabyte
        let containerUsage: [String: DockerUsage] = [
            "c1": DockerUsage(cpuPercent: 7, memoryBytes: megabytes(312), memoryLimitBytes: containerLimit),
            "c2": DockerUsage(cpuPercent: 2, memoryBytes: megabytes(148), memoryLimitBytes: containerLimit)
        ]

        system.applyPreview(
            snapshot: snapshot,
            cpuHistory: history,
            apps: apps,
            processes: processes,
            containers: [api, database, cache],
            containerUsage: containerUsage
        )
    }
}
