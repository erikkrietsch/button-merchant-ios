//
// Client.swift
//
// Copyright © 2018 Button, Inc. All rights reserved. (https://usebutton.com)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//

import Foundation
import UIKit

internal enum Service: String {
    
    case postInstall = "v1/web/deferred-deeplink"
    case activity = "v1/activity/order"
    case order = "v1/mobile-order"
    
    static var baseURL = "https://api.usebutton.com/"
    
    var url: URL {
        return URL(string: Service.baseURL + self.rawValue)!
    }
}

internal protocol ClientType: class {
    var session: URLSessionType { get }
    var userAgent: UserAgentType { get }
    func fetchPostInstallURL(parameters: [String: Any], _ completion: @escaping (URL?, String?) -> Void)
    func trackOrder(parameters: [String: Any], _ completion: ((Error?) -> Void)?)
    func reportOrder(parameters: [String: Any],
                     encodedApplicationId: String,
                     _ completion: ((Error?) -> Void)?)
    init(session: URLSessionType, userAgent: UserAgentType)
}

internal final class Client: ClientType {

    var session: URLSessionType
    var userAgent: UserAgentType
    var requestCoordinator: RequestCoordinatorType
    
    init(session: URLSessionType, userAgent: UserAgentType) {
        self.session = session
        self.userAgent = userAgent
        requestCoordinator = RequestCoordinator(session: session)
    }
    
    func fetchPostInstallURL(parameters: [String: Any], _ completion: @escaping (URL?, String?) -> Void) {
        let request = urlRequest(url: Service.postInstall.url, parameters: parameters)
        enqueueRequest(request: request, completion: { data, _ in
            guard let data = data,
                let responseDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let object = responseDict?["object"] as? [String: Any],
                let action = object["action"] as? String,
                let attributionObject = object["attribution"] as? [String: Any] else {
                    completion(nil, nil)
                    return
            }
            completion(URL(string: action)!, attributionObject["btn_ref"] as? String)
        })
    }
    
    func trackOrder(parameters: [String: Any], _ completion: ((Error?) -> Void)?) {
        let request = urlRequest(url: Service.activity.url, parameters: parameters)
        enqueueRequest(request: request) { _, error in
            if let completion = completion {
                completion(error)
            }
        }
    }
    
    func reportOrder(parameters: [String: Any],
                     encodedApplicationId: String,
                     _ completion: ((Error?) -> Void)?) {
        var request = urlRequest(url: Service.order.url, parameters: parameters)
        request.setValue("Basic \(encodedApplicationId):", forHTTPHeaderField: "Authorization")
        requestCoordinator.enqueueRetriableRequest(request: request,
                                                   attempt: 0,
                                                   maxRetries: 3,
                                                   retryIntervalInMS: 100) { _, error in
                                                    if let completion = completion {
                                                        completion(error)
                                                    }
        }
    }
    
}

internal extension Client {
    
    func urlRequest(url: URL, parameters: [String: Any]? = nil) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(userAgent.stringRepresentation, forHTTPHeaderField: "User-Agent")
        if let parameters = parameters {
            urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return urlRequest
    }
    
    func enqueueRequest(request: URLRequest, completion: @escaping (Data?, Error?) -> Void) {
        let task = session.dataTask(with: request) { data, response, error  in
            guard let data = data,
                let response = response as? HTTPURLResponse, 200...299 ~= response.statusCode else {
                    completion(nil, error)
                    return
            }
            completion(data, nil)
        }
        task.resume()
    }
    
    func enqueueRetriableRequest(request: URLRequest,
                                 attempt: Int = 0,
                                 maxRetries: Int = 3,
                                 retryIntervalInMS: Int = 100,
                                 completion: @escaping (Data?, Error?) -> Void) {
        let task = session.dataTask(with: request) { data, response, error  in
            
            var shouldRetry = true
            if let response = response as? HTTPURLResponse, data != nil {
                switch response.statusCode {
                case 429, 500...599:
                    shouldRetry = true
                default:
                    shouldRetry = false
                }
            }
            
            guard shouldRetry, attempt + 1 <= maxRetries else {
                completion(data, error)
                return
            }
            
            var delay = retryIntervalInMS
            delay *= attempt == 0 ? 1 : 2 << (attempt - 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000.0, execute: {
                self.enqueueRetriableRequest(request: request,
                                             attempt: attempt + 1,
                                             maxRetries: maxRetries,
                                             retryIntervalInMS: retryIntervalInMS,
                                             completion: completion)
            })
        }
        task.resume()
    }
}
