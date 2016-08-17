import Foundation
import Result

/// A Moya Plugin receives callbacks to perform side effects wherever a request is sent or received.
///
/// for example, a plugin may be used to
///     - log network requests
///     - hide and show a network avtivity indicator
///     - inject additional information into a request
public protocol PluginType {
    /// Called immediately before a request is sent over the network (or stubbed).
    func willSendRequest(_ request: RequestType, target: TargetType)

    // Called after a response has been received, but before the MoyaProvider has invoked its completion handler.
    func didReceiveResponse(_ result: Result<Moya.Response, Moya.Error>, target: TargetType)
}

/// Request type used by willSendRequest plugin function.
public protocol RequestType {

    // Note:
    //
    // We use this protocol instead of the Alamofire request to avoid leaking that abstraction.
    // A plugin should not know about Alamofire at all.

    /// Retrieve an NSURLRequest represetation.
    var request: URLRequest? { get }

    /// Authenticates the request with a username and password.
    func authenticate(user: String, password: String, persistence: URLCredential.Persistence) -> Self

    /// Authnenticates the request with a NSURLCredential instance.
    func authenticate(usingCredential credential: URLCredential) -> Self
}
