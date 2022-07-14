//
//  TezosRpcProvider.swift
//  
//
//  Created by xgblin on 2022/6/9.
//

import Foundation
//import Alamofire
import PromiseKit
import CryptoSwift

public struct TezosRpcProvider {
    public var nodeUrl:String
    
    public init(nodeUrl: String) {
        self.nodeUrl = nodeUrl
    }
    
    public func getXTZBalance(address:String) -> Promise<String> {
        return Promise<String> { seal in
            sendRequest(request: GetBalanceURL(nodeUrl: self.nodeUrl, address: address)).done { (result:String) in
                seal.fulfill(result)
            }.catch { error in
                seal.reject(error)
            }
        }
    }
    
    public func getFa1_2TokenBalancee(address:String,mint:String,chainId:String) -> Promise<String> {
        return Promise { seal in
            let requestParmer = RunViewURL(nodeUrl: nodeUrl, input: TezosArg.literal(.string(address)), chainId: chainId, mint: mint, entrypoint: "getBalance")
            sendRequest(request: requestParmer, method: .post).done { (result:FA1_2BalanceResult) in
                seal.fulfill(result.balance)
            }.catch { error in
                seal.reject(error)
            }
        }
    }
    
    public func getFa2TokenBalancee(address:String,contract:String,tokenId:String,chainId:String)-> Promise<String> {
        return Promise<String> { seal in
            let prim = TezosPrim(prim: "Pair", args: [TezosArg.literal(.string(address)),TezosArg.literal(.int(tokenId))])
            let input = TezosArg.prim(prim)
            let requestParmer = RunViewURL(nodeUrl: nodeUrl, input: input, chainId: chainId, mint: contract, entrypoint: "balance_of")
            sendRequest(request: requestParmer, method: .post).done { (result:FA2BalanceResult) in
                seal.fulfill(result.balance)
            }.catch { error in
                seal.reject(error)
            }
        }
    }
    
    public func getNfts(address:String) -> Promise<[TezosNFTResult]> {
        return Promise<[TezosNFTResult]> {seal in
            sendRequest(request: GetNFTURL(address: address, limit:"1000")).done { (results:Array<TezosNFTResult>) in
                seal.fulfill(results)
            }.catch { error in
                seal.reject(error)
            }
        }
    }
}

// MARK:  Tool request
extension  TezosRpcProvider {
    
    public func getMetadata(address:String) -> Promise<TezosBlockchainMetadata> {
        return Promise<TezosBlockchainMetadata> {seal in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let counter = try getCounter(address: address).wait()
                    let blocksHead = try getBlocksHead().wait()
                    let managerKey = try getManagerKey(address: address).wait()
                    let constants = try getConstants().wait()
                    seal.fulfill(TezosBlockchainMetadata(blockHash: blocksHead.hash ?? "", protocolString: blocksHead.protocolString ?? "", counter: (Int(counter) ?? 0) + 1, key:managerKey, constants: constants))
                } catch let error {
                    seal.reject(error)
                }
            }
        }
    }
    
    public func getSimulationResponse(operations:[TransactionOperation],metadata:TezosBlockchainMetadata) -> Promise<SimulationResponse> {
        return Promise<SimulationResponse> { seal in
            let request = RunOperationURL(nodeUrl: nodeUrl, operations: operations, metadata: metadata)
            sendRequest(request: request,method: .post).done { (result:OperationContents) in
                let parser = TezosSimulationResponseParser(constants: metadata.constants)
                if let responseResult = parser.parseSimulation(result: result) {
                    seal.fulfill(responseResult)
                } else {
                    seal.reject(TezosRpcProviderError.server(message: "error data"))
                }
            }.catch { error in
                seal.reject(error)
            }
        }
    }
    
    public func forge(branch:String,operations:[TransactionOperation]) -> Promise<String> {
        return Promise<String> {seal in
            getHeadHash().then{ (headHash:String) -> Promise<String> in
                let request = ForgeURL(nodeUrl: nodeUrl, headHash:headHash , operations: operations, branch: branch)
                return sendRequest(request: request, method: .post)
            }.done { forgeString in
                seal.fulfill(forgeString)
            }.catch { error in
                seal.reject(error)
            }
        }
    }
}

// MARK: preapplyTransaction
extension TezosRpcProvider {
    
    public func preapplyTransaction(transaction:TezosTransaction) -> Promise<TezosTransaction> {
        return Promise<TezosTransaction> {seal in
            calculateFees(operations: transaction.operations, metadata: transaction.metadata).then { havefeeOperations -> Promise< String> in
                transaction.configOperations(operations: havefeeOperations)
                return forge(branch: transaction.branch, operations: havefeeOperations)
            }.done { forgeResult in
                transaction.forgeString = forgeResult
                seal.fulfill(transaction)
            }.catch { error in
                seal.reject(error)
            }
        }
    }
    
    func calculateFees(operations:[TransactionOperation],metadata:TezosBlockchainMetadata) -> Promise<[TransactionOperation]> {
        return Promise<[TransactionOperation]> {seal in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try getSimulationResponse(operations: operations, metadata: metadata).wait()
                    let forgeResult = try forge(branch: metadata.branch, operations: operations).wait()
                    let service = TezosFeeEstimatorService()
                    var haveFeeOperations = [TransactionOperation]()
                    operations.forEach { operation in
                        let haveFeeOperation = service.calculateFeesAndCreateOperation(response: response, operation: operation, operationSize: service.getForgedOperationsSize(forgeResult: forgeResult))
                        haveFeeOperations.append(haveFeeOperation)
                    }
                    seal.fulfill(haveFeeOperations)
                } catch let error {
                    seal.reject(error)
                }
            }
        }
    }
}

// MARK: sendtransaction
extension  TezosRpcProvider {
    
    public func sendTransaction(transaction:TezosTransaction) -> Promise<String> {
        return Promise<String> {seal in
            if let _sendString = transaction.sendString{
                do {
                    let isSuccess = try preapplySignedTransaction(transaction: transaction).wait()
                    if isSuccess {
                        let hash = try injectOperation(sendString:_sendString).wait()
                        seal.fulfill(hash)
                    }else {
                        seal.reject(TezosRpcProviderError.unknown)
                    }
                } catch let error {
                    seal.reject(error)
                }
            }else {
                seal.reject(TezosRpcProviderError.server(message: ""))
            }
        }
    }
    
    
    func preapplySignedTransaction(transaction:TezosTransaction) -> Promise<Bool> {
        return Promise<Bool> {seal in
            if let _signature = transaction.signatureString {
                let request = PreapplyOperationURL(nodeUrl: nodeUrl, branch: transaction.branch, operations: transaction.operations, protocolString: transaction.protocolString, signature:_signature)
                sendRequest(request: request, method: .post).done { (results:PreappleOperationResult) in
                    let isSuccess = TezosPreapplyResponseParser.parse(results: results)
                    seal.fulfill(isSuccess)
                }.catch { error in
                    seal.reject(error)
                }
            }else {
                seal.reject(TezosRpcProviderError.server(message: ""))
            }
        }
    }
    
    func injectOperation(sendString:String) -> Promise<String> {
        return Promise<String> { seal in
            let request = InjectOperationURL(nodeUrl: nodeUrl, sendString: sendString)
            sendRequest(request: request,method: .post).done { (result:String) in
                seal.fulfill(result)
            }.catch { error in
                seal.reject(error)
            }
        }
    }
}

// MARK: Base Data
extension  TezosRpcProvider {
    public func getChainID() -> Promise<String> {
        return Promise<String> {seal in
            sendRequest(request: GetChainIDURL(nodeUrl: nodeUrl)).done { (result:String) in
                seal.fulfill(result)
            }.catch { error in
                seal.reject(error)
            }
        }
    }
    
    public func getHeadHash() -> Promise<String> {
        return Promise<String> {seal in
            sendRequest(request: GetHeadHashURL(nodeUrl: nodeUrl)).done { (result:String) in
                seal.fulfill(result)
            }.catch { error in
                seal.reject(error)
            }
        }
    }
    
    public func getHeadHeader() -> Promise<Int> {
        return Promise<Int> {seal in
            sendRequest(request: GetHeadHeader(nodeUrl: nodeUrl)).done { (result:GetHeadHeaderResult) in
                seal.fulfill(result.level ?? 0)
            }.catch { error in
                seal.reject(error)
            }
        }
    }
    
    public func getNetworkConstants() -> Promise<String> {
        return Promise<String> {seal in
            sendRequest(request: GetNetworkConstantsURL(nodeUrl: nodeUrl)).done { (result:String) in
                seal.fulfill(result)
            }.catch { error in
                seal.reject(error)
            }
        }
    }
    
    public func getManagerKey(address:String) -> Promise<String> {
        return Promise<String> {seal in
            sendRequest(request: GetManagerKeyURL(nodeUrl: nodeUrl,address: address)).done { (result:String) in
                seal.fulfill(result)
            }.catch { error in
                seal.reject(error)
            }
        }
    }
    
    public func getCounter(address:String) -> Promise<String> {
        return Promise<String> {seal in
            sendRequest(request: GetCounterURL(nodeUrl: nodeUrl,address: address)).done { (result:String) in
                seal.fulfill(result)
            }.catch { error in
                seal.reject(error)
            }
        }
    }
    
    public func getBlocksHead() -> Promise<GetChainHeadResult> {
        return Promise<GetChainHeadResult> {seal in
            sendRequest(request: GetBlockHeadURL(nodeUrl: nodeUrl)).done { (result:GetChainHeadResult) in
                seal.fulfill(result)
            }.catch { error in
                seal.reject(error)
            }
        }
    }
    
    public func getConstants()-> Promise<TezosNetworkConstants> {
        return Promise<TezosNetworkConstants> {seal in
            sendRequest(request: GetNetworkConstantsURL(nodeUrl: nodeUrl)).done { (result:TezosNetworkConstants) in
                seal.fulfill(result)
            }.catch { error in
                seal.reject(error)
            }
        }
    }
}

extension TezosRpcProvider {
    
    func sendRequest<T:Codable>(request:RPCURLRequest,method:HTTPMethod = .get) -> Promise<T> {
        return Promise<T> { seal in
            DispatchQueue.main.async {
                let config = URLSessionConfiguration.default
                let urlSession = URLSession(configuration: config)
                guard let urlRequest = self.configUrlRequest(request: request, method: method) else {
                    seal.reject(TezosRpcProviderError.server(message: "Wrong parmaters"))
                    return
                }
                let task = urlSession.dataTask(with: urlRequest) { (data, response, error) in
                    guard error == nil else {
                        seal.reject(error!)
                        return
                    }
                    guard data != nil else {
                        seal.reject(TezosRpcProviderError.server(message: "Node response is empty"))
                        return
                    }
                    if let resp = try? JSONDecoder().decode(T.self, from: data!) {
                        seal.fulfill(resp)
                    }
                }
                task.resume()
            }
        }
    }
    
    func configUrlRequest(request:RPCURLRequest,method:HTTPMethod) -> URLRequest?{
        guard let url = URL(string: request.RPCURLString) else { return nil }
        var urlRequest = URLRequest(url: url)
        if method == .post {
            guard let payload = request.parmaters else {
                return nil
            }
            do {
                urlRequest.httpMethod = "POST"
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
                let jsonData: Data
                if let stringPayload = payload as? String, let stringData = stringPayload.data(using: .utf8) {
                    jsonData = stringData
                } else {
                    jsonData = try payload.toJSONData()
                }
                urlRequest.httpBody = jsonData
            }
            catch {
                return nil
            }
        }
        return urlRequest
    }
}

private extension Encodable {
    func toJSONData() throws -> Data {
        return try JSONEncoder().encode(self)
    }
}

public enum HTTPMethod: String {
    case post = "POST"
    case get = "GET"
}

public enum TezosRpcProviderError: LocalizedError {
    case unknown
    case server(message: String)
    public var errorDescription: String? {
        switch self {
        case .server(let message):
            return message
        default:
            return "Unknown error"
        }
    }
}

