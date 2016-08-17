import Foundation
import Result

/// Closure to be executed when a request has completed.
public typealias Completion = (_ result: Result<Moya.Response, Moya.Error>) -> ()

/// Closure to be executed when a request has completed.
public typealias ProgressBlock = (_ progress: ProgressResponse) -> Void

public struct ProgressResponse {
    public let totalBytes: Int64
    public let bytesExpected: Int64
    public let response: Response?

    init(totalBytes: Int64 = 0, bytesExpected: Int64 = 0, response: Response? = nil) {
        self.totalBytes = totalBytes
        self.bytesExpected = bytesExpected
        self.response = response
    }

    public var progress: Double {
        return bytesExpected > 0 ? min(Double(totalBytes) / Double(bytesExpected), 1.0) : 1.0
    }

    public var completed: Bool {
        return totalBytes >= bytesExpected && response != nil
    }
}

/// Request provider class. Requests should be made through this class only.
public class MoyaProvider<Target: TargetType> {

    /// Closure that defines the endpoints for the provider.
    public typealias EndpointClosure = (Target) -> Endpoint<Target>

    /// Closure that decides if and what request should be performed
    public typealias RequestResultClosure = (Result<URLRequest, Moya.Error>) -> Void

    /// Closure that resolves an Endpoint into an RequestResult.
    public typealias RequestClosure = (Endpoint<Target>, RequestResultClosure) -> Void

    /// Closure that decides if/how a request should be stubbed.
    public typealias StubClosure = (Target) -> Moya.StubBehavior

    public let endpointClosure: EndpointClosure
    public let requestClosure: RequestClosure
    public let stubClosure: StubClosure
    public let manager: Manager

    /// A list of plugins
    /// e.g. for logging, network activity indicator or credentials
    public let plugins: [PluginType]

    public let trackInflights: Bool

    public internal(set) var inflightRequests = Dictionary<Endpoint<Target>, [Moya.Completion]>()

    /// Initializes a provider.
    public init(endpointClosure: EndpointClosure = MoyaProvider.DefaultEndpointMapping,
        requestClosure: RequestClosure = MoyaProvider.DefaultRequestMapping,
        stubClosure: StubClosure = MoyaProvider.NeverStub,
        manager: Manager = MoyaProvider<Target>.DefaultAlamofireManager(),
        plugins: [PluginType] = [],
        trackInflights: Bool = false) {

            self.endpointClosure = endpointClosure
            self.requestClosure = requestClosure
            self.stubClosure = stubClosure
            self.manager = manager
            self.plugins = plugins
            self.trackInflights = trackInflights
    }

    /// Returns an Endpoint based on the token, method, and parameters by invoking the endpointsClosure.
    public func endpoint(_ token: Target) -> Endpoint<Target> {
        return endpointClosure(token)
    }

    /// Designated request-making method. Returns a Cancellable token to cancel the request later.
    public func request(_ target: Target, completion: Moya.Completion) -> Cancellable {
        return self.request(target, queue: nil, completion: completion)
    }

    /// Designated request-making method with queue option. Returns a Cancellable token to cancel the request later.
    public func request(_ target: Target, queue: DispatchQueue?, progress: Moya.ProgressBlock? = nil, completion: Moya.Completion) -> Cancellable {
        return requestNormal(target, queue: queue, progress: progress, completion: completion)
    }

    /// When overriding this method, take care to `notifyPluginsOfImpendingStub` and to perform the stub using the `createStubFunction` method.
    /// Note: this was previously in an extension, however it must be in the original class declaration to allow subclasses to override.
    func stubRequest(_ target: Target, request: URLRequest, completion: Moya.Completion, endpoint: Endpoint<Target>, stubBehavior: Moya.StubBehavior) -> CancellableToken {
        let cancellableToken = CancellableToken { }
        notifyPluginsOfImpendingStub(request, target: target)
        let plugins = self.plugins
        let stub: () -> () = createStubFunction(cancellableToken, forTarget: target, withCompletion: completion, endpoint: endpoint, plugins: plugins)
        switch stubBehavior {
        case .immediate:
            stub()
        case .delayed(let delay):
            let killTimeOffset = Int64(CDouble(delay) * CDouble(NSEC_PER_SEC))
            let killTime = DispatchTime.now() + Double(killTimeOffset) / Double(NSEC_PER_SEC)
            DispatchQueue.main.asyncAfter(deadline: killTime) {
                stub()
            }
        case .never:
            fatalError("Method called to stub request when stubbing is disabled.")
        }

        return cancellableToken
    }
}

/// Mark: Stubbing

public extension MoyaProvider {

    // Swift won't let us put the StubBehavior enum inside the provider class, so we'll
    // at least add some class functions to allow easy access to common stubbing closures.

    public final class func NeverStub(_: Target) -> Moya.StubBehavior {
        return .never
    }

    public final class func ImmediatelyStub(_: Target) -> Moya.StubBehavior {
        return .immediate
    }

    public final class func DelayedStub(_ seconds: TimeInterval) -> (Target) -> Moya.StubBehavior {
        return { _ in return .delayed(seconds: seconds) }
    }
}

public func convertResponseToResult(_ response: HTTPURLResponse?, data: Data?, error: NSError?) ->
    Result<Moya.Response, Moya.Error> {
    switch (response, data, error) {
    case let (.some(response), data, .none):
        let response = Moya.Response(statusCode: response.statusCode, data: (data ?? Data()) as Data, response: response)
        return .success(response)
    case let (_, _, .some(error)):
        let error = Moya.Error.underlying(error)
        return .failure(error)
    default:
        let error = Moya.Error.underlying(NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: nil))
        return .failure(error)
    }
}
