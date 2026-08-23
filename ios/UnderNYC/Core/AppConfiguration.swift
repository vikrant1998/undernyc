import Foundation

enum AppConfiguration {
    // Show every line returned by the nearby endpoint. Search mode can narrow
    // this set and automatically follows the closest matching train.
    static let maximumVisibleTrains = 20

    static var backendURL: URL {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: "UnderNYCBackendURL") as? String,
            let url = URL(string: value),
            url.scheme == "https" || url.host == "localhost"
        else {
            fatalError("Set UNDERNYC_BACKEND_URL in Config.xcconfig")
        }
        return url
    }
}
