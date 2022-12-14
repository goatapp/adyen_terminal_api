//
//  PaymentRequest.swift
//  GOATGROUP - Adyen TerminalAPI Implementation
//
//  Created by Javier Lanatta on 11/11/2022.
//

import Foundation

public class PaymentRequest: TerminalRequest {
    public let saleData: SaleData
    public let paymentTransaction: PaymentTransaction
    
    enum CodingKeys: String, CodingKey {
        case saleData
        case paymentTransaction
    }

    init(saleData: SaleData, paymentTransaction: PaymentTransaction) {
        self.saleData = saleData
        self.paymentTransaction = paymentTransaction
    }
    
    override public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(saleData, forKey: .saleData)
        try container.encode(paymentTransaction, forKey: .paymentTransaction)
    }
}
