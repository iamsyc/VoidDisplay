//
//  WebServer.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/14.
//

import Network
import CoreGraphics
import ImageIO
import OSLog

class WebServer{
    var streamConnection:NWConnection?=nil
    var listener:NWListener?
    let displayPage:String
    private let isSharingProvider: () -> Bool
    private let frameProvider: () -> Data?
    private let requestHandler = WebRequestHandler()
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
                    AppLog.web.info("Sharing stopped while streaming; closing client connection.")
                    stop()
                    connection.cancel()
                    return
                }
                guard let frame = frameProvider() else { return }

                let boundary = "--nextFrameK9_4657\r\n"
                let contentHeader = "Content-Type: image/jpg\r\n"
                let contentLength = "Content-Length: \(frame.count)\r\n\r\n"
                let frameData = Data(boundary.utf8) + Data(contentHeader.utf8) + Data(contentLength.utf8) + frame + Data("\r\n".utf8)
                connection.send(content: frameData, completion: .contentProcessed({ error in
                    if let error {
                        AppErrorMapper.logFailure("Stream frame send", error: error, logger: AppLog.web)
                    }
                }))
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
        listener = try NWListener(using: .tcp, on: port)
        listener?.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: .main)
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    AppErrorMapper.logFailure("Connection failed", error: error, logger: AppLog.web)
                    if self.streamConnection === connection {
                        self.streamPump?.stop()
                        self.streamPump = nil
                        self.streamConnection = nil
                    }
                    connection.cancel()
                case .cancelled:
                    AppLog.web.info("Connection cancelled.")
                    if self.streamConnection === connection {
                        self.streamPump?.stop()
                        self.streamPump = nil
                        self.streamConnection = nil
                    }
                default:
                    break
                }
            }
            connection.receive(minimumIncompleteLength: 0, maximumLength: 999) { content, contentContext, isComplete, error in
                if let error {
                    AppErrorMapper.logFailure("Receive HTTP request", error: error, logger: AppLog.web)
                }
                guard let content else {
                    AppLog.web.notice("Received empty request content; closing connection.")
                    connection.cancel()
                    return
                }
                if isComplete {
                    _ = contentContext
                }
                guard let request = parseHTTPRequest(from: content) else {
                    AppLog.web.notice("Failed to parse HTTP request; closing connection.")
                    connection.cancel()
                    return
                }

                let decision = self.requestHandler.decision(
                    forPath: request.path,
                    isSharing: self.isSharingProvider()
                )

                switch decision {
                case .showDisplayPage:
                    connection.send(
                        content: self.requestHandler.responseData(for: .showDisplayPage, displayPage: self.displayPage),
                        completion: .contentProcessed { error in
                            if let error {
                                AppErrorMapper.logFailure("Send display page response", error: error, logger: AppLog.web)
                            }
                            connection.cancel()
                        }
                    )
                case .openStream:
                    self.streamConnection?.cancel()
                    self.streamConnection = connection
                    AppLog.web.info("Open MJPEG stream for client.")
                    connection.send(
                        content: self.requestHandler.responseData(for: .openStream, displayPage: self.displayPage),
                        completion: .contentProcessed { error in
                            if let error {
                                AppErrorMapper.logFailure("Send stream response header", error: error, logger: AppLog.web)
                            }
                        }
                    )
                    self.streamPump?.stop()
                    self.streamPump = StreamPump(
                        connection: connection,
                        isSharingProvider: self.isSharingProvider,
                        frameProvider: frameProvider
                    )
                    self.streamPump?.start()
                case .sharingUnavailable, .notFound:
                    connection.send(
                        content: self.requestHandler.responseData(for: decision, displayPage: self.displayPage),
                        completion: .contentProcessed { error in
                            if let error {
                                AppErrorMapper.logFailure("Send HTTP error response", error: error, logger: AppLog.web)
                            }
                            connection.cancel()
                        }
                    )
                }
            }
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
