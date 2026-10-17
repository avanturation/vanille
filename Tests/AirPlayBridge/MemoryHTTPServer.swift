import Foundation
import Network

/// Experiment only: media remains in memory and the listener binds to loopback.
/// No LAN listener, persisted audio, external service or AirPlay protocol is used.
final class MemoryHTTPServer {
    struct Response {
        var status = 200
        var contentType: String
        var data: Data
        var pending = false
    }
    private let queue = DispatchQueue(label: "Vanille.AirPlayLab.HTTP")
    private var listener: NWListener?
    private var connections: [UUID:NWConnection] = [:]
    private let resource: (String) -> Response?
    private(set) var port: UInt16 = 0
    private var requestCount = 0
    private var sentCount = 0
    private var partRequests=0
    private var fullSegmentRequests=0
    private var blockingReloadRequests=0
    var metrics:(requests:Int,bytes:Int,parts:Int,fullSegments:Int,blockingReloads:Int) {
        queue.sync { (requestCount,sentCount,partRequests,fullSegmentRequests,blockingReloadRequests) }
    }
    let token = UUID().uuidString
    var onReady: ((URL) -> Void)?
    var onError: ((String) -> Void)?

    init(resource: @escaping (String) -> Response?) { self.resource = resource }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = listener?.port?.rawValue else { return }
                self.port = port
                let url = URL(string: "http://127.0.0.1:\(port)/\(self.token)/")!
                DispatchQueue.main.async { self.onReady?(url) }
            case .failed(let error):
                DispatchQueue.main.async { self.onError?(error.localizedDescription) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.connections.removeValue(forKey: id)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(connection, id:id, accumulated:Data())
        queue.asyncAfter(deadline:.now()+10) { [weak self, weak connection] in
            connection?.cancel(); self?.connections.removeValue(forKey:id)
        }
    }

    private func receive(_ connection:NWConnection, id:UUID, accumulated:Data) {
        connection.receive(minimumIncompleteLength:1, maximumLength:16_384) { [weak self] data,_,complete,error in
            guard let self else { return }
            var request = accumulated
            if let data { request.append(data) }
            guard request.count <= 16_384, error == nil else { connection.cancel(); return }
            if let end = request.range(of:Data("\r\n\r\n".utf8)) {
                self.respond(connection, header:String(decoding:request[..<end.upperBound],as:UTF8.self))
            } else if complete { connection.cancel() }
            else { self.receive(connection,id:id,accumulated:request) }
        }
    }

    private func respond(_ connection:NWConnection, header:String,deadline:Date?=nil) {
        let lines = header.components(separatedBy:"\r\n")
        let first = (lines.first ?? "").split(separator:" ")
        guard first.count >= 2, first[0] == "GET" || first[0] == "HEAD",
              first[1].hasPrefix("/\(token)/") else { send(connection,status:404,type:"text/plain",body:Data()); return }
        let path = String(first[1].dropFirst(token.count+2))
        if deadline == nil {
            if path.hasPrefix("p"),path.contains(".m4s") { partRequests += 1 }
            if path.hasPrefix("s"),path.contains(".m4s") { fullSegmentRequests += 1 }
            if path.contains("_HLS_msn=") { blockingReloadRequests += 1 }
        }
        guard let response = resource(path) else { send(connection,status:404,type:"text/plain",body:Data()); return }
        if response.pending {
            let end=deadline ?? Date().addingTimeInterval(3)
            guard Date()<end else { send(connection,status:503,type:"text/plain",body:Data());return }
            queue.asyncAfter(deadline:.now()+0.02) { [weak self,weak connection] in
                if let self,let connection { self.respond(connection,header:header,deadline:end) }
            }
            return
        }
        requestCount += 1
        var body = response.data
        var status = response.status
        var extra = "Accept-Ranges: bytes\r\n"
        if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range: bytes=") }) {
            let raw = rangeLine.dropFirst("range: bytes=".count).split(separator:"-",omittingEmptySubsequences:false)
            if let start = raw.first.flatMap({ Int($0) }), start >= 0, start < body.count {
                let last = raw.count>1 ? (Int(raw[1]) ?? body.count-1) : body.count-1
                let finish = min(body.count-1,max(start,last))
                extra += "Content-Range: bytes \(start)-\(finish)/\(body.count)\r\n"
                body = body.subdata(in:start..<(finish+1)); status = 206
            } else { send(connection,status:416,type:"text/plain",body:Data()); return }
        }
        send(connection,status:status,type:response.contentType,body:body,extra:extra,head:first[0] == "HEAD")
    }

    private func send(_ connection:NWConnection,status:Int,type:String,body:Data,extra:String="",head:Bool=false) {
        var data = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : status == 206 ? "Partial Content" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n".utf8)
        if !head { data.append(body) }
        sentCount += data.count
        connection.send(content:data,completion:.contentProcessed { _ in connection.cancel() })
    }

    func stop() {
        queue.sync {
            listener?.cancel(); listener = nil
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }
    deinit { stop() }
}
