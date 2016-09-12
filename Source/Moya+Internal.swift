import Foundation
import Result

/// Internal extension to keep the inner-workings outside the main Moya.swift file.
internal extension MoyaProvider {
    // Yup, we're disabling these. The function is complicated, but breaking it apart requires a large effort.
    // swiftlint:disable cyclomatic_complexity
    // swiftlint:disable function_body_length
    /// Performs normal requests.
    func requestNormal(_ target: Target, queue: DispatchQueue?, progress: Moya.ProgressBlock?, completion: @escaping Moya.Completion) -> Cancellable {
        let endpoint = self.endpoint(target)
        let stubBehavior = self.stubClosure(target)
        let cancellableToken = CancellableWrapper()

        if trackInflights {
            objc_sync_enter(self)
            var inflightCompletionBlocks = self.inflightRequests[endpoint]
            inflightCompletionBlocks?.append(completion)
            self.inflightRequests[endpoint] = inflightCompletionBlocks
            objc_sync_exit(self)

            if inflightCompletionBlocks != nil {
                return cancellableToken
            } else {
                objc_sync_enter(self)
                self.inflightRequests[endpoint] = [completion]
                objc_sync_exit(self)
            }
        }

        let performNetworking = { (requestResult: Result<URLRequest, Moya.Error>) in
            if cancellableToken.cancelled {
                self.cancelCompletion(completion, target: target)
                return
            }

            var request: URLRequest!

            switch requestResult {
            case .success(let urlRequest):
                request = urlRequest
            case .failure(let error):
                completion(.failure(error))
                return
            }

            switch stubBehavior {
            case .never:
                let networkCompletion: Moya.Completion = { result in
                    if self.trackInflights {
                        self.inflightRequests[endpoint]?.forEach({ $0(result) })

                        objc_sync_enter(self)
                        self.inflightRequests.removeValue(forKey: endpoint)
                        objc_sync_exit(self)
                    } else {
                        completion(result)
                    }
                }
                switch target.task {
                case .request:
                    cancellableToken.innerCancellable = self.sendRequest(target, request: request as URLRequest, queue: queue, progress: progress, completion: networkCompletion)
                case .upload(.file(let file)):
                    cancellableToken.innerCancellable = self.sendUploadFile(target, request: request as URLRequest, queue: queue, file: file, progress: progress, completion: networkCompletion)
                case .upload(.multipart(let multipartBody)):
                    guard !multipartBody.isEmpty && target.method.supportsMultipart else {
                        fatalError("\(target) is not a multipart upload target.")
                    }
                    cancellableToken.innerCancellable = self.sendUploadMultipart(target, request: request as URLRequest, queue: queue, multipartBody: multipartBody, progress: progress, completion: networkCompletion)
                case .download(.request(let destination)):
                    cancellableToken.innerCancellable = self.sendDownloadRequest(target, request: request as URLRequest, queue: queue, destination: destination, progress: progress, completion: networkCompletion)
                }
            default:
                cancellableToken.innerCancellable = self.stubRequest(target, request: request as URLRequest, completion: { result in
                    if self.trackInflights {
                        self.inflightRequests[endpoint]?.forEach({ $0(result) })

                        objc_sync_enter(self)
                        self.inflightRequests.removeValue(forKey: endpoint)
                        objc_sync_exit(self)
                    } else {
                        completion(result)
                    }
                    }, endpoint: endpoint, stubBehavior: stubBehavior)
            }
        }

        requestClosure(endpoint, performNetworking)

        return cancellableToken
    }
    // swiftlint:enable cyclomatic_complexity
    // swiftlint:enable function_body_length

    func cancelCompletion(_ completion: Moya.Completion, target: Target) {
        let error = Moya.Error.underlying(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil))
        plugins.forEach { $0.didReceiveResponse(.failure(error), target: target) }
        completion(.failure(error))
    }

    /// Creates a function which, when called, executes the appropriate stubbing behavior for the given parameters.
    final func createStubFunction(_ token: CancellableToken, forTarget target: Target, withCompletion completion: @escaping Moya.Completion, endpoint: Endpoint<Target>, plugins: [PluginType]) -> (() -> ()) {
        return {
            if token.cancelled {
                self.cancelCompletion(completion, target: target)
                return
            }

            switch endpoint.sampleResponseClosure() {
            case .networkResponse(let statusCode, let data):
                let response = Moya.Response(statusCode: statusCode, data: data, response: nil)
                plugins.forEach { $0.didReceiveResponse(.success(response), target: target) }
                completion(.success(response))
            case .networkError(let error):
                let error = Moya.Error.underlying(error)
                plugins.forEach { $0.didReceiveResponse(.failure(error), target: target) }
                completion(.failure(error))
            }
        }
    }

    /// Notify all plugins that a stub is about to be performed. You must call this if overriding `stubRequest`.
    final func notifyPluginsOfImpendingStub(_ request: URLRequest, target: Target) {
        let alamoRequest = manager.request(request)
        plugins.forEach { $0.willSendRequest(alamoRequest, target: target) }
    }
}

fileprivate extension MoyaProvider {
    fileprivate func sendUploadMultipart(_ target: Target, request: URLRequest, queue: DispatchQueue?, multipartBody: [MultipartFormData], progress: Moya.ProgressBlock? = nil, completion: @escaping Moya.Completion) -> CancellableWrapper {
        let cancellable = CancellableWrapper()

        let multipartFormData = { (form: RequestMultipartFormData) -> Void in
            for bodyPart in multipartBody {
                switch bodyPart.provider {
                case .data(let data):
                    form.append(data, withName: bodyPart.name, fileName: bodyPart.fileName, mimeType: bodyPart.mimeType)
                case .file(let url):
                    form.append(url, withName: bodyPart.name, fileName: bodyPart.fileName, mimeType: bodyPart.mimeType)
                case .stream(let stream, let length):
                    form.append(stream, withLength: length, name: bodyPart.name, fileName: bodyPart.fileName, mimeType: bodyPart.mimeType)
                }
            }

            if let parameters = target.parameters {
                parameters
                    .flatMap { (key, value) in multipartQueryComponents(key, value) }
                    .forEach { (key, value) in
                        if let data = value.data(using: String.Encoding.utf8, allowLossyConversion: false) {
                            form.append(data, withName: key)
                        }
                }
            }
        }
        manager.upload(multipartFormData: multipartFormData, with: request) { (result: MultipartFormDataEncodingResult) in
            switch result {
            case .success(let alamoRequest, _, _):
                if cancellable.cancelled {
                    self.cancelCompletion(completion, target: target)
                    return
                }
                cancellable.innerCancellable = self.sendAlamofireRequest(alamoRequest, target: target, queue: queue, progress: progress, completion: completion)
            case .failure(let error):
                completion(.failure(Moya.Error.underlying(error as NSError)))
            }
        }

        return cancellable
    }

    internal func sendUploadFile(_ target: Target, request: URLRequest, queue: DispatchQueue?, file: URL, progress: ProgressBlock? = nil, completion: @escaping Completion) -> CancellableToken {
        let alamoRequest = manager.upload(file, with: request)
        return self.sendAlamofireRequest(alamoRequest, target: target, queue: queue, progress: progress, completion: completion)
    }

    internal func sendDownloadRequest(_ target: Target, request: URLRequest, queue: DispatchQueue?, destination: @escaping DownloadDestination, progress: ProgressBlock? = nil, completion: @escaping Completion) -> CancellableToken {
        let alamoRequest = manager.download(request, to: destination)
        return self.sendAlamofireRequest(alamoRequest, target: target, queue: queue, progress: progress, completion: completion)
    }

    internal func sendRequest(_ target: Target, request: URLRequest, queue: DispatchQueue?, progress: Moya.ProgressBlock?, completion: @escaping Moya.Completion) -> CancellableToken {
        let alamoRequest = manager.request(request)
        return sendAlamofireRequest(alamoRequest, target: target, queue: queue, progress: progress, completion: completion)
    }

    internal func sendAlamofireRequest(_ alamoRequest: Request, target: Target, queue: DispatchQueue?, progress: Moya.ProgressBlock?, completion: @escaping Moya.Completion) -> CancellableToken {
        // Give plugins the chance to alter the outgoing request
        let plugins = self.plugins
        plugins.forEach { $0.willSendRequest(alamoRequest, target: target) }

        // Perform the actual request
        if let progress = progress {
            alamoRequest
                .progress { (bytesWritten, totalBytesWritten, totalBytesExpected) in
                    let sendProgress: () -> () = {
                        progress(ProgressResponse(totalBytes: totalBytesWritten, bytesExpected: totalBytesExpected))
                    }

                    if let queue = queue {
                        queue.async(execute: sendProgress)
                    } else {
                        sendProgress()
                    }
            }
        }

        alamoRequest
            .response(queue: queue) { (_, response: HTTPURLResponse?, data: Data?, error: NSError?) -> () in
                let result = convertResponseToResult(response, data: data, error: error)
                // Inform all plugins about the response
                plugins.forEach { $0.didReceiveResponse(result, target: target) }
                completion(result)
        }


        alamoRequest.resume()

        return CancellableToken(request: alamoRequest)
    }
}

/**
 Encode parameters for multipart/form-data
 */
private func multipartQueryComponents(_ key: String, _ value: AnyObject) -> [(String, String)] {
    var components: [(String, String)] = []

    if let dictionary = value as? [String: AnyObject] {
        for (nestedKey, value) in dictionary {
            components += multipartQueryComponents("\(key)[\(nestedKey)]", value)
        }
    } else if let array = value as? [AnyObject] {
        for value in array {
            components += multipartQueryComponents("\(key)[]", value)
        }
    } else {
        components.append((key, "\(value)"))
    }

    return components
}
