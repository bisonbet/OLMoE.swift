//
//  Context.swift
//  OLMoE.swift
//
//  Created by Ken Adamson on 11/17/24.
//


import Foundation
import llama

public class Context {
    let pointer: OpaquePointer
    init(_ model: Model, _ params: llama_context_params) {
        self.pointer = llama_init_from_model(model, params)
    }
    deinit {
        llama_free(pointer)
    }
    func decode(_ batch: llama_batch) {
        let ret = llama_decode(pointer, batch)

        if ret < 0 {
            fatalError("llama_decode failed: \(ret)")
        } else if ret > 0 {
            print("llama_decode returned \(ret)")
        }
    }
}
