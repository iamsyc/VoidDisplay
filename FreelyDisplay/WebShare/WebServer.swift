//
//  WebServer.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/14.
//

import Network
import CoreGraphics
import ImageIO

class WebServer{
    var streamConnection:NWConnection?=nil
    var listener:NWListener?
    let displayPage:String
    private let isSharingProvider: () -> Bool
    private let frameProvider: () -> Data?
    private var streamPump: StreamPump?

    private final class StreamPump {
        weak var connection: NWConnection?
        let isSharingProvider: () -> Bool
        let frameProvider: () -> Data?
        private var timer: Timer?

        init(
            connection: NWConnection,
            isSharingProvider: @escaping () -> Bool,
            frameProvider: @escaping () -> Data?
        ) {
            self.connection = connection
            self.isSharingProvider = isSharingProvider
            self.frameProvider = frameProvider
        }

        func start() {
            stop()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
                guard let self, let connection else { return }
                guard isSharingProvider() else {
                    stop()
                    connection.cancel()
                    return
                }
                guard let frame = frameProvider() else { return }

                let boundary = "--nextFrameK9_4657\r\n"
                let contentHeader = "Content-Type: image/jpg\r\n"
                let contentLength = "Content-Length: \(frame.count)\r\n\r\n"
                let frameData = Data(boundary.utf8) + Data(contentHeader.utf8) + Data(contentLength.utf8) + frame + Data("\r\n".utf8)
                connection.send(content: frameData, completion: .contentProcessed({ _ in }))
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }
    }

    init(
        using port:NWEndpoint.Port = .http,
        isSharingProvider: @escaping () -> Bool,
        frameProvider: @escaping () -> Data?
    ) throws{
        self.isSharingProvider = isSharingProvider
        self.frameProvider = frameProvider
        displayPage=try String(contentsOfFile: Bundle.main.path(forResource: "displayPage", ofType: "html")!, encoding: .utf8)
        do{
            try listener=NWListener(using: .tcp, on: port)
            listener?.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: .main)
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .cancelled, .failed(_):
                        if self.streamConnection === connection {
                            self.streamPump?.stop()
                            self.streamPump = nil
                            self.streamConnection = nil
                        }
                        connection.cancel()
                    default:
                        break
                    }
                }
                connection.receive(minimumIncompleteLength: 0, maximumLength: 999) { content, contentContext, isComplete, error in
                    guard let content else {
                        connection.cancel()
                        return
                    }
                    if let request = parseHTTPRequest(from: content) {
                        
                        guard let path=URL(string: request.path) else {return}
                        
                        if path.isRoot{
                            connection.send(content: ("HTTP/1.1 200 OK\r\n\r\n"+self.displayPage).data(using: .utf8), completion: .contentProcessed({error in
                                connection.cancel()
                            }))
                        }else if(path.hasSubDir(in: URL(string: "/stream")!)){
                            guard self.isSharingProvider() else {
                                let response = """
                                HTTP/1.1 503 Service Unavailable\r
                                Content-Type: text/plain; charset=utf-8\r
                                Cache-Control: no-cache\r
                                Connection: close\r
                                \r
                                Sharing has stopped.
                                """
                                connection.send(content: Data(response.utf8), completion: .contentProcessed({ _ in
                                    connection.cancel()
                                }))
                                return
                            }

                            self.streamConnection?.cancel()
                            self.streamConnection=connection
                            connection.send(content: ("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=nextFrameK9_4657\r\nConnection: keep-alive\r\nCache-Control: no-cache\r\n\r\n").data(using: .utf8), completion: .contentProcessed({_ in}))
                            self.streamPump?.stop()
                            self.streamPump = StreamPump(
                                connection: connection,
                                isSharingProvider: self.isSharingProvider,
                                frameProvider: frameProvider
                            )
                            self.streamPump?.start()
                        }else{
                            connection.send(content: ("HTTP/1.1 404 OK\r\n\r\n").data(using: .utf8), completion: .contentProcessed({error in
                                connection.cancel()
                            }))
                        }
                    }
                    
                    
                    
                }
            }
        }catch{
            throw error
        }
        
    }
    
    public func startListener(){
        listener?.start(queue: .global())
    }

    func disconnectStreamClient() {
        streamPump?.stop()
        streamPump = nil
        streamConnection?.cancel()
        streamConnection = nil
    }

    func stopListener() {
        disconnectStreamClient()
        listener?.cancel()
        listener = nil
    }
    
    deinit {
        stopListener()
    }
    
}
