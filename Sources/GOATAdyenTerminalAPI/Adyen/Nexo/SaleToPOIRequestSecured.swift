//
//  SaleToPOIRequestSecured.swift
//  GOATGROUP - Adyen TerminalAPI Implementation
//
//  Created by Javier Lanatta on 11/11/2022.
//

import Foundation

public struct SaleToPOIRequestSecured: Encodable {
    public let saleToPOIRequest: SaleToPOIMessageSecured
}
