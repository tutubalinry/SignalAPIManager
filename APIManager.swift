//
//  Created by Roman Tutubalin on 28.11.17.
//  Copyright © 2017 Roman Tutubalin. All rights reserved.
//

import Foundation

class APIManager: NSObject, URLSessionDelegate, URLSessionDataDelegate {
    static let shared = APIManager()
    
    private let defaultConfiguration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return configuration
    }()
    
    var configuration: URLSessionConfiguration!
    var session: URLSession!
    
    override init() {
        super.init()
        update(configuration: defaultConfiguration)
    }
    
    func update(configuration: URLSessionConfiguration) {
        self.configuration = configuration
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    
    func request<R>(url: String, httpMethod: HTTPMethod = .get, parameters: [String : Any]? = nil, retryCount: Int = 0, retrySignal: Signal<Request<R>>? = nil) -> Signal<Request<R>> {
        var signal: Signal<Request<R>>
        if let rs = retrySignal {
            signal = rs
        } else {
            signal = Signal<Request>()
        }
        
        if var components = URLComponents(string: url) {
            guard var compsURL = components.url else {
                DispatchQueue.main.async {
                    signal.fire(.failed(error: APIError.invalidURL))
                }
                
                return signal
            }
            
            if httpMethod == .get {
                if let params = parameters {
                    var queries: [String] = []
                    for (key, value) in params {
                        queries.append("\(key)=\(value)")
                    }
                    components.query = queries.joined(separator: "&")
                    
                    guard let modifiedURL = components.url else {
                        DispatchQueue.main.async {
                            signal.fire(.failed(error: APIError.invalidURL))
                        }
                        
                        return signal
                    }
                    
                    compsURL = modifiedURL
                }
            }
            
            var urlRequest = URLRequest(url: compsURL)
            urlRequest.httpMethod = httpMethod.rawValue
            if let params = parameters {
                if httpMethod != .get {
                    urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: params, options: JSONSerialization.WritingOptions(rawValue: 0))
                }
            }
            
            let task = session.dataTask(with: urlRequest) { (data, response, error) in
                if let error = error {
                    if retryCount > 0 {
                        signal = self.request(url: url, httpMethod: httpMethod, parameters: parameters, retryCount: retryCount - 1, retrySignal: signal)
                    } else {
                        DispatchQueue.main.async {
                            signal.fire(.failed(error: error))
                        }
                    }
                    
                    return
                }
                
                guard let response = response as? HTTPURLResponse else {
                    DispatchQueue.main.async {
                        signal.fire(.failed(error: APIError.wrongResponse))
                    }
                    return
                }
                
                if response.statusCode == 200 {
                    if let data = data {
                        let json = try? JSONSerialization.jsonObject(with: data, options: .allowFragments)
                        
                        DispatchQueue.main.async {
                            signal.fire(.success(data: R.parse(json: json)))
                        }
                    }
                } else {
                    if retryCount > 0 {
                        signal = self.request(url: url, httpMethod: httpMethod, parameters: parameters, retryCount: retryCount - 1, retrySignal: signal)
                    } else {
                        DispatchQueue.main.async {
                            switch response.statusCode {
                            case 300...399  : signal.fire(.failed(error: APIError.redirection))
                            case 400...499  : signal.fire(.failed(error: APIError.wrongRequest))
                            case 500...599  : signal.fire(.failed(error: APIError.serverError))
                            default         : signal.fire(.failed(error: APIError.unknownError))
                            }
                        }
                    }
                }
            }
        
            task.resume()
        }
        
        DispatchQueue.main.async {
            signal.fire(.inProgress)
        }
        
        return signal
    }
}

enum Request<R: Parsable> {
    case inProgress
    case success(data: Response<R>)
    case failed(error: Error)
}

enum APIError: Error {
    case invalidURL
    case wrongResponse
    case redirection
    case wrongRequest
    case serverError
    case unknownError
}

enum HTTPMethod: String {
    case get, post
}

enum Response<R> {
    case item(R?), array([R])
}

protocol Parsable {
    init?(json: Any?)
    
    static func parse(json: Any?) -> Response<Self>
}

extension Parsable {
    static func parse(json: Any?) -> Response<Self> {
        if let array = json as? [Any] {
            return Response.array(array.flatMap { any -> Self? in Self(json: any) })
        }
        
        return Response.item(Self(json: json))
    }
}

struct DefaultResponse: Parsable {
    let any: Any?
    
    init?(json: Any?) {
        debugPrint(json)
        self.any = json
    }
}
