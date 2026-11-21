import Foundation

/// `azpim://` links (AppFlow › Deep links). Values are escaped down to the unreserved characters: `&`, `=`, `+`,
/// `#` or `%` in a favorite name must reach the app unchanged (`+` is read as a space by some senders).
public enum DeepLink {
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// `azpim://activate?favorite=<name>`.
    public static func activate(favorite name: String) -> URL? {
        url(host: "activate", item: "favorite", value: name)
    }

    /// `azpim://role?id=<eligible role id>`.
    public static func role(id: String) -> URL? {
        url(host: "role", item: "id", value: id)
    }

    /// Decoded value of a query item of a link, or nil when absent.
    public static func value(of item: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == item }?.value
    }

    private static func url(host: String, item: String, value: String) -> URL? {
        var components = URLComponents()
        components.scheme = "azpim"
        components.host = host
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        components.percentEncodedQueryItems = [URLQueryItem(name: item, value: encoded)]
        return components.url
    }
}
