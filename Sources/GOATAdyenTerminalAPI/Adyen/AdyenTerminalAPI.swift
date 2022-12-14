//
//  RequestMaker.swift
//  GOATGROUP - Adyen TerminalAPI Implementation
//
//  Created by Javier Lanatta on 7/26/22.
//

import Foundation
import Security
import Logging

class AdyenTerminalAPI: NSObject {
    let logger = Logger(label: "adyen_terminal_api")
    let terminal: AdyenTerminal
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    var urlSession: URLSession!

    init(terminal: AdyenTerminal) {
        self.terminal = terminal

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSS'Z'"

        encoder.keyEncodingStrategy = .convertToPascalCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        decoder.keyDecodingStrategy = .convertFromPascalCase
        decoder.dateDecodingStrategy = .formatted(formatter)
    }

    func perform<T:TerminalRequest, R:TerminalResponse>(request: AdyenTerminalRequest<T>) async throws -> AdyenTerminalResponse<R> {
        let encryptor = SaleToPOIMessageSecuredEncryptor()
        let credentials = terminal.encryptionCredentialDetails
        let encodedSaleToPOIRequestSecuredData = try encodeRequest(request: request)
        do {
            let responseData = try await self.performRequest(encodedSaleToPOIRequestSecuredData: encodedSaleToPOIRequestSecuredData)
            let securedResponse = try decoder.decode(SaleToPOIResponseSecured.self, from: responseData)
            let response = try encryptor.descrypt(saleToPOIMessageSecured: securedResponse.saleToPOIResponse, encryptionCredentialDetails: credentials)
            logger.info("ADYEN DECODED RESPONSE: \(String(data: response, encoding: .utf8)!)")
            return try decoder.decode(AdyenTerminalResponse.self, from: response)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost:
                throw AdyenTerminalAPIError.cannotConnectToHost
            case .serverCertificateUntrusted:
                throw AdyenTerminalAPIError.serverCertificateUntrusted
            default:
                throw error
            }
        } catch let error as DecodingError {
            var errorDescription = ""
            switch error {
            case .typeMismatch(let key, let value):
                errorDescription = "\(error.localizedDescription) [TypeMismatch for \(R.self) with key: \(key), value: \(value)]"
            case .valueNotFound(let key, let value):
                errorDescription = "\(error.localizedDescription) [ValueNotFound for \(R.self) with key: \(key), value: \(value)]"
            case .keyNotFound(let key, let value):
                errorDescription = "\(error.localizedDescription) [KeyNotFound for \(R.self) with key: \(key), value: \(value)]"
            case .dataCorrupted(let key):
                errorDescription = "\(error.localizedDescription) [DataCorrupted for \(R.self) with key: \(key)]"
            default:
                errorDescription = error.localizedDescription
            }
            throw AdyenTerminalAPIError.decoding(error: errorDescription)
        } catch {
            throw error
        }
    }
    
    func performResponseless<T:TerminalRequest>(request: AdyenTerminalRequest<T>) async throws {
        let encodedSaleToPOIRequestSecuredData = try encodeRequest(request: request)

        do {
            _ = try await self.performRequest(encodedSaleToPOIRequestSecuredData: encodedSaleToPOIRequestSecuredData)
        } catch {
            if let error = error as? URLError, error.code == .serverCertificateUntrusted {
                throw AdyenTerminalAPIError.serverCertificateUntrusted
            }

            throw error
        }
    }
    
    private func encodeRequest<T:TerminalRequest>(request: AdyenTerminalRequest<T>) throws -> Data {
        let encryptor = SaleToPOIMessageSecuredEncryptor()
        let credentials = terminal.encryptionCredentialDetails

        let data = try encoder.encode(request)
        guard let text = String(data: data, encoding: .ascii) else {
            throw AdyenTerminalAPIError.unknown(error: "Error while encoding the request")
        }

        logger.info("ADYEN DECODED REQUEST: \(text)")

        let saleToPOIRequest = try encryptor.encrypt(saleToPOIMessage: text, messageHeader: request.saleToPOIRequest.messageHeader, encryptionCredentialDetails: credentials)
        
        let SaleToPOIRequestSecured = SaleToPOIRequestSecured(saleToPOIRequest: saleToPOIRequest)
        let encodedSaleToPOIRequestSecuredData = try encoder.encode(SaleToPOIRequestSecured)

        if let logline = String(data: encodedSaleToPOIRequestSecuredData, encoding: .utf8) {
            logger.info("ADYEN ENCODED REQUEST: \(logline)")
        }
        
        return encodedSaleToPOIRequestSecuredData
    }

    private func performRequest(encodedSaleToPOIRequestSecuredData: Data) async throws -> Data {
        if self.urlSession == nil {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = terminal.timeout
            configuration.timeoutIntervalForResource = terminal.timeout
            self.urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        }
        
        let deviceURL = URL(string: "https://\(terminal.ip):8443/nexo")!
        var urlRequest = URLRequest(url: deviceURL)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = encodedSaleToPOIRequestSecuredData

        logger.info("ADYEN REQUEST: \(String(data: encodedSaleToPOIRequestSecuredData, encoding: .utf8)!)")

        let (data, response) = try await urlSession.data(for: urlRequest)
        if let rs = response as? HTTPURLResponse, let responseText = String(data: data, encoding: .utf8) {
            logger.info("ADYEN RESPONSE [\(rs.statusCode)]: \(responseText)")
        }

        return data
    }
}

///
/// https://stackoverflow.com/questions/34223291/ios-certificate-pinning-with-swift-and-nsurlsession
///
extension AdyenTerminalAPI: URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if (challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust) {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                var error: CFError?
                let isServerTrusted = SecTrustEvaluateWithError(serverTrust, &error)

                if error != nil {
                    logger.info("Warning, server is trusted: \(error?.localizedDescription ?? "---"). Will try to evaluate server trust using internal certificate.")
                }

                if isServerTrusted {
                    return (URLSession.AuthChallengeDisposition.useCredential, URLCredential(trust:serverTrust))
                } else {
                    let certificateFile = Bundle.main.path(forResource: "adyen-terminalfleet-test", ofType: "crt")
                    guard let certificateFile = certificateFile, let certificateData = NSData(contentsOfFile: certificateFile) as? Data else {
                        logger.error("ERROR: 'adyen-terminalfleet-test.crt' file not found. Server trust is invalid!")
                        return (URLSession.AuthChallengeDisposition.cancelAuthenticationChallenge, nil)
                    }

                    if let serverCertificates = SecTrustCopyCertificateChain(serverTrust) as? Array<SecCertificate> {
                        logger.info("Device certificates found: \(serverCertificates.count)")
                        for serverCertificate in serverCertificates {
                            let serverCertificateData = SecCertificateCopyData(serverCertificate)
                            let data = CFDataGetBytePtr(serverCertificateData);
                            let size = CFDataGetLength(serverCertificateData);
                            let cert1 = NSData(bytes: data, length: size)

                            var cfName: CFString?
                            SecCertificateCopyCommonName(serverCertificate, &cfName)

                            if cert1.isEqual(to: certificateData) {
                                logger.info("Device certificate \(cfName.debugDescription) is valid!")
                                return (URLSession.AuthChallengeDisposition.useCredential, URLCredential(trust:serverTrust))
                            } else {
                                logger.info("Device certificate \(cfName.debugDescription) is not valid!")
                            }
                        }
                        logger.info("Trust certificate NOT FOUND, accepting authentication challenge anyway :/")
                        return (URLSession.AuthChallengeDisposition.useCredential, URLCredential(trust:serverTrust))
                    }
                }
            }
        }

        // Pinning failed
        return (URLSession.AuthChallengeDisposition.cancelAuthenticationChallenge, nil)
    }
}
