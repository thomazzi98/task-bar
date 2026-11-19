import Foundation
import Testing
@testable import TaskBarCore

@Suite("Listening port parsing")
struct ListeningPortParserTests {
    /// Field output as lsof 4.x prints it for `-nP -iTCP -sTCP:LISTEN -F pcnLu`.
    private let realistic = """
    p4312
    cnode
    u501
    Lrafael
    f23
    n*:3000
    f24
    n[::1]:3000
    p1187
    cpostgres
    u501
    Lrafael
    f5
    n127.0.0.1:5432
    f6
    n[::1]:5432
    p902
    ccontrolce
    u0
    Lroot
    f8
    n*:5000
    p4520
    cvite
    u501
    Lrafael
    f19
    n127.0.0.1:5173
    f20
    n[::1]:5173
    f21
    n*:9229
    """

    @Test func readsOneRowPerProcessAndPort() {
        let ports = ListeningPortParser.parse(realistic)
        // node 3000 (IPv4 and IPv6 merged), postgres 5432, controlce 5000, vite 5173, node 9229.
        #expect(ports.count == 5)
        #expect(Set(ports.map(\.id)).count == ports.count)
    }

    @Test func sortsByPortThenPID() {
        let ports = ListeningPortParser.parse(realistic)
        #expect(ports.map(\.port) == [3000, 5000, 5173, 5432, 9229])
    }

    @Test func mergesIPv4AndIPv6OfTheSamePortAndProcess() throws {
        let node = try #require(ListeningPortParser.parse(realistic).first { $0.port == 3000 })
        #expect(node.pid == 4312)
        #expect(node.command == "node")
        #expect(node.user == "rafael")
        #expect(node.userID == 501)
        // A wildcard listener is reachable from the network, so it is not loopback-only.
        #expect(node.address == "*")
        #expect(node.isLoopbackOnly == false)
    }

    @Test func marksLoopbackOnlyPorts() throws {
        let ports = ListeningPortParser.parse(realistic)
        let postgres = try #require(ports.first { $0.port == 5432 })
        #expect(postgres.isLoopbackOnly)
        #expect(postgres.address == "127.0.0.1")

        let vite = try #require(ports.first { $0.port == 5173 })
        #expect(vite.isLoopbackOnly)
    }

    @Test func keepsOwnerDetailsForRootProcesses() throws {
        let control = try #require(ListeningPortParser.parse(realistic).first { $0.port == 5000 })
        #expect(control.user == "root")
        #expect(control.userID == 0)
        #expect(control.command == "controlce")
    }

    @Test func handlesWildcardAndIPv6Addresses() throws {
        let output = """
        p77
        cruby
        u501
        Lrafael
        f4
        n[::]:8080
        f5
        n0.0.0.0:8081
        """
        let ports = ListeningPortParser.parse(output)
        #expect(ports.count == 2)
        let ipv6 = try #require(ports.first { $0.port == 8080 })
        #expect(ipv6.address == "::")
        #expect(ipv6.isLoopbackOnly == false)
        let ipv4 = try #require(ports.first { $0.port == 8081 })
        #expect(ipv4.address == "0.0.0.0")
    }

    @Test func keepsWildcardAddressWhenLoopbackComesFirst() throws {
        let output = """
        p55
        cdocker
        u501
        Lrafael
        n127.0.0.1:6000
        n*:6000
        """
        let port = try #require(ListeningPortParser.parse(output).first)
        #expect(port.address == "*")
        #expect(port.isLoopbackOnly == false)
    }

    @Test func ignoresConnectedSocketsAndGarbage() {
        let output = """
        p300
        cpython3
        u501
        Lrafael
        n127.0.0.1:8000->127.0.0.1:53512
        nnot-an-address
        n*:0
        n*:notaport

        """
        let ports = ListeningPortParser.parse(output)
        #expect(ports.count == 1)
        #expect(ports.first?.port == 8000)
    }

    @Test func emptyOutputMeansNothingListening() {
        #expect(ListeningPortParser.parse("").isEmpty)
    }

    @Test func attachesServiceFromThePortNumber() throws {
        let ports = ListeningPortParser.parse(realistic)
        let postgres = try #require(ports.first { $0.port == 5432 })
        #expect(postgres.service == PortService(label: "PostgreSQL", isDatabase: true))
    }
}

@Suite("Known ports")
struct KnownPortsTests {
    @Test func namesWellKnownPorts() {
        #expect(KnownPorts.service(for: 3000, command: "node")?.label == "Dev server")
        #expect(KnownPorts.service(for: 4200, command: "node")?.label == "Angular")
        #expect(KnownPorts.service(for: 5173, command: "node")?.label == "Vite")
        #expect(KnownPorts.service(for: 5174, command: "node")?.label == "Vite")
        #expect(KnownPorts.service(for: 8080, command: "java")?.label == "HTTP")
        #expect(KnownPorts.service(for: 9229, command: "node")?.label == "Node inspector")
        #expect(KnownPorts.service(for: 11211, command: "memcached")?.label == "Memcached")
        #expect(KnownPorts.service(for: 9200, command: "java")?.label == "Elasticsearch")
        #expect(KnownPorts.service(for: 5672, command: "beam.smp")?.label == "RabbitMQ")
        #expect(KnownPorts.service(for: 2375, command: "dockerd")?.label == "Docker API")
        #expect(KnownPorts.service(for: 2376, command: "dockerd")?.label == "Docker API")
    }

    @Test func marksDatabasesAndOnlyDatabases() {
        for port: UInt16 in [5432, 3306, 27017, 6379] {
            #expect(KnownPorts.service(for: port, command: "whatever")?.isDatabase == true)
        }
        #expect(KnownPorts.service(for: 3000, command: "node")?.isDatabase == false)
        #expect(KnownPorts.service(for: 5672, command: "beam.smp")?.isDatabase == false)
    }

    @Test func marksOnlyHTTPLikePortsAsWeb() {
        #expect(KnownPorts.service(for: 3000, command: "node")?.isWebLike == true)
        #expect(KnownPorts.service(for: 8080, command: "java")?.isWebLike == true)
        #expect(KnownPorts.service(for: 9229, command: "node")?.isWebLike == false)
        #expect(KnownPorts.service(for: 5432, command: "postgres")?.isWebLike == false)
    }

    @Test func infersServiceFromCommandForUnknownPorts() {
        #expect(KnownPorts.service(for: 5433, command: "postgres") == PortService(label: "PostgreSQL", isDatabase: true))
        #expect(KnownPorts.service(for: 27018, command: "mongod") == PortService(label: "MongoDB", isDatabase: true))
        #expect(KnownPorts.service(for: 6380, command: "redis-server") == PortService(label: "Redis", isDatabase: true))
        #expect(KnownPorts.service(for: 3307, command: "mysqld") == PortService(label: "MySQL", isDatabase: true))
        #expect(KnownPorts.service(for: 4000, command: "node") == PortService(label: "Node.js", isWebLike: true))
        #expect(KnownPorts.service(for: 8888, command: "python3.12") == PortService(label: "Python", isWebLike: true))
        #expect(KnownPorts.service(for: 4567, command: "ruby") == PortService(label: "Ruby", isWebLike: true))
        #expect(KnownPorts.service(for: 7000, command: "java") == PortService(label: "Java", isWebLike: true))
        #expect(KnownPorts.service(for: 7001, command: "com.docker.backend") == PortService(label: "Docker"))
    }

    @Test func portNumberWinsOverCommandName() {
        // A dev server that happens to sit on the Postgres port is still reported as Postgres.
        #expect(KnownPorts.service(for: 5432, command: "node")?.label == "PostgreSQL")
    }

    @Test func returnsNilForUnknownPortAndCommand() {
        #expect(KnownPorts.service(for: 7777, command: "controlce") == nil)
    }
}

@Suite("Port filter")
struct PortFilterTests {
    @Test func developmentFilterHidesDatabases() {
        let dev = PortService(label: "Vite", isWebLike: true)
        let database = PortService(label: "Redis", isDatabase: true)
        #expect(PortFilter.all.includes(dev) && PortFilter.all.includes(database))
        #expect(PortFilter.development.includes(dev))
        #expect(!PortFilter.development.includes(database))
        #expect(!PortFilter.databases.includes(dev))
        #expect(PortFilter.databases.includes(database))
    }

    @Test func unknownServicesAppearUnderAllAndDevelopment() {
        #expect(PortFilter.all.includes(nil))
        #expect(PortFilter.development.includes(nil))
        #expect(!PortFilter.databases.includes(nil))
    }
}

@Suite("Port stop rules")
struct PortStopRulesTests {
    private func port(pid: Int32, userID: UInt32 = 501, user: String = "rafael") -> ListeningPort {
        ListeningPort(
            pid: pid,
            command: "node",
            user: user,
            userID: userID,
            port: 3000,
            address: "*",
            isLoopbackOnly: false
        )
    }

    @Test func allowsOwnProcesses() {
        #expect(PortStopRules.block(for: port(pid: 4312), currentUserID: 501, ownPID: 999) == nil)
    }

    @Test func neverAllowsTaskBarItselfOrLowPIDs() {
        #expect(PortStopRules.block(for: port(pid: 999), currentUserID: 501, ownPID: 999) == .protectedProcess)
        #expect(PortStopRules.block(for: port(pid: 1), currentUserID: 501, ownPID: 999) == .protectedProcess)
        #expect(PortStopRules.block(for: port(pid: 0), currentUserID: 501, ownPID: 999) == .protectedProcess)
    }

    @Test func refusesProcessesOwnedByOtherUsers() {
        #expect(
            PortStopRules.block(for: port(pid: 902, userID: 0, user: "root"), currentUserID: 501, ownPID: 999)
                == .ownedByOtherUser("root")
        )
    }
}
