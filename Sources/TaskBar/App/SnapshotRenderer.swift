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
        let prepare: (AppEnvironment, DemoData) -> Void
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
            environment.appState.select(.agents)
        },
        Scene(name: "agent-detail") { environment, demo in
            environment.appState.select(.agents)
            environment.agents.select(demo.featuredSessionID)
        },
        Scene(name: "calendar") { environment, _ in
            environment.agents.select(nil)
            environment.appState.select(.calendar)
        },
        Scene(name: "system") { environment, _ in
            environment.appState.select(.system)
        },
        Scene(name: "settings") { environment, _ in
            environment.appState.isShowingSettings = true
        }
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
            let environment = AppEnvironment(paths: paths, defaults: defaults)
            let demo = DemoData.install(in: environment)

            var images: [String: NSImage] = [:]
            for scene in scenes {
                defaults.set(scene.rendersNotes, forKey: "editor.opensInPreview")
                scene.prepare(environment, demo)
                let image = try render(environment.rootView(), appearance: appearanceName)
                images[scene.name] = image
                let url = directory.appendingPathComponent("\(scene.name)-\(suffix).png")
                try write(image, to: url)
                written.append(url)
            }

            let banner = composeBanner(
                [images["task-detail"], images["agents"], images["system"]].compactMap { $0 },
                isDark: suffix == "dark"
            )
            let bannerURL = directory.appendingPathComponent("banner-\(suffix).png")
            try write(banner, to: bannerURL)
            written.append(bannerURL)
        }
        return written
    }

    // MARK: Rendering

    private static func render(_ view: some View, appearance: NSAppearance.Name) throws -> NSImage {
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

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        window.contentView = nil

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
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

    static func install(in environment: AppEnvironment, now: Date = Date()) -> DemoData {
        let featured = installTasks(in: environment.tasks)
        let promptID = installNotes(in: environment.notes)
        let sessionID = installAgents(in: environment.agents, now: now)
        installAgenda(in: environment.agenda, now: now)
        installSystem(in: environment.system)
        return DemoData(featuredTaskID: featured, promptNoteID: promptID, featuredSessionID: sessionID)
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
