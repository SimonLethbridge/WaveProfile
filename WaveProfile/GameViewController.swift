//
//  GameViewController.swift
//  WaveProfile
//
//  Created by Simon Lethbridge on 03/07/2016.
//  Copyright (c) 2016 Simon Lethbridge. All rights reserved.
//

import Cocoa
import MetalKit

let MaxBuffers = 3
let ConstantBufferSize = 1024*1024



struct ProfileCoord
{
    var x: Float = 0
    var y: Float = 0
};

struct WaveParams
{
    var Qbase :     Float = 0.0
    var amplitude : Float = 0.0
    var height :    Float = 0.0
};

struct Constants 
{
    var colour = vector_float4(1.0, 1.0, 1.0, 1.0)
    var offset = vector_float4(0.0, 0.0, 0.0, 1.0)
}



class GameViewController: NSViewController, MTKViewDelegate {
    
    var device: MTLDevice! = nil
    
    var commandQueue: MTLCommandQueue! = nil
    var commandQueueKernel: MTLCommandQueue! = nil
    var pipelineState: MTLRenderPipelineState! = nil
    var kernelPipeLineState: MTLComputePipelineState! = nil
    var vertexIn:       MTLBuffer! = nil
    var indexBuffer:    MTLBuffer! = nil
    var waveProfileBuffers:     [MTLBuffer]! = nil
    var wpParamsBuffer: MTLBuffer! = nil
    var vertexCount: Int = 0
    var indexCount: Int = 0
    var waveProfileCount: Int = 0
    
    let inflightSemaphore = dispatch_semaphore_create(MaxBuffers)
    var bufferIndex = 0
    

    override func viewDidLoad() {
        
        super.viewDidLoad()
        
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else { // Fallback to a blank NSView, an application could also fallback to OpenGL here.
            print("Metal is not supported on this device")
            self.view = NSView(frame: self.view.frame)
            return
        }

        // setup view properties
        let view = self.view as! MTKView
        view.delegate = self
        view.device = device
        view.sampleCount = 4
        
        loadAssets()
//        (vertexIn, vertexCount, indexBuffer, indexCount, waveProfileBuffers, wpParamsBuffer, waveProfileCount) = createProfileBuffers(device)
        var profile_buffers = createProfileBuffers(device)
        vertexIn         = profile_buffers.vertexIn
        vertexCount      = profile_buffers.vertexCount
        indexBuffer      = profile_buffers.indexBuffer
        indexCount       = profile_buffers.indexCount
        waveProfileBuffers        = profile_buffers.waveProfileBuffers
        wpParamsBuffer   = profile_buffers.wpParamsBuffer
        waveProfileCount = profile_buffers.waveProfileCount
        
    }
    
    func loadAssets() {
        
        // load any resources required for rendering
        let view = self.view as! MTKView
        commandQueue = device.newCommandQueue()
        commandQueue.label = "main command queue"
        
        commandQueueKernel = device.newCommandQueue()
        commandQueueKernel.label = "kernel command queue"
        
        let defaultLibrary = device.newDefaultLibrary()!
        let fragmentProgram = defaultLibrary.newFunctionWithName("passThroughFragment")!
        let vertexProgram = defaultLibrary.newFunctionWithName("passThroughVertex")!
        
        let pipelineStateDescriptor = MTLRenderPipelineDescriptor()
        pipelineStateDescriptor.vertexFunction = vertexProgram
        pipelineStateDescriptor.fragmentFunction = fragmentProgram
        pipelineStateDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineStateDescriptor.sampleCount = view.sampleCount
        
        do {
            try pipelineState = device.newRenderPipelineStateWithDescriptor(pipelineStateDescriptor)
        } catch let error {
            print("Failed to create pipeline state, error \(error)")
        }
                
        if let kernelProfileFunction = defaultLibrary.newFunctionWithName("profileKernel")
        {
            // let kernelPipelineStateDescriptor = MTLRenderPipelineDescriptor()
            kernelPipeLineState = try? device.newComputePipelineStateWithFunction(kernelProfileFunction)
        }
    }
 
    func createWaveProfileInputBuffer(device : MTLDevice) -> (vertexIn: MTLBuffer, vertexCount:Int, indexBuffer: MTLBuffer, indexCount:Int)
    {
        var vector : [ProfileCoord] = [ ]
        var indexes : [UInt16] = []
        let NUM_POINTS = 512
        
        vector.reserveCapacity(NUM_POINTS)
        for i in 0..<NUM_POINTS
        {
            let xx = 2.0 * (Float(i) / Float(NUM_POINTS-1)) - 1.0
            vector +=  [ ProfileCoord(x:xx, y:1.0), ProfileCoord(x:xx, y: -1.0) ]
            
            if i > 0
            {
                let a = UInt16(2*(i-1))
                let b = a+1
                let c = b+1
                let d = c+1
                indexes += [ a, c, b, c, d, b]
            }
        }
        
        let bufferLengthBytes = vector.count*sizeof(ProfileCoord)
        var inBuffer = device.newBufferWithBytes(vector, length: bufferLengthBytes, options: [])
        inBuffer.label = "in"
        
        var indexBuffer = device.newBufferWithBytes(indexes, length: indexes.count * sizeof(UInt16), options: [])
        indexBuffer.label = "index buffer"
        
        return (vertexIn: inBuffer, vertexCount:vector.count, indexBuffer: indexBuffer, indexCount: indexes.count)
    }
    
    func createProfileBuffers(device : MTLDevice) -> ( 
        vertexIn: MTLBuffer,
        vertexCount : Int,
        indexBuffer: MTLBuffer,
        indexCount : Int, 
        waveProfileBuffers: [MTLBuffer],  
        wpParamsBuffer: MTLBuffer,
        waveProfileCount: Int)
    {
        let (vertexIn, vertexCount, indexBuffer, indexCount) = createWaveProfileInputBuffer(device)
        let qValues : [Float] = [0.0, 0.2, 0.4, 0.6]
//        var wp : [WaveParams] = []
        let paramsBufferFloatsPerSet = 256 / sizeof(Float)
        var waveParametersFloats = [Float](count:paramsBufferFloatsPerSet*qValues.count, repeatedValue:0.0)
        var waveProfileBuffers : [MTLBuffer] = []
        let bufferLengthBytes = vertexCount*sizeof(ProfileCoord)
                
        var i = 0
        for q in qValues
        {
            let wp = WaveParams(Qbase: q, amplitude: 0.2, height: -0.5+1.6*q)
            waveParametersFloats[paramsBufferFloatsPerSet*i + 0] = wp.Qbase
            waveParametersFloats[paramsBufferFloatsPerSet*i + 1] = wp.amplitude
            waveParametersFloats[paramsBufferFloatsPerSet*i + 2] = wp.height 
            i += 1

            waveProfileBuffers += [ device.newBufferWithLength(bufferLengthBytes, options: []) ]            
        }
        var waveProfileParamsBuffer = device.newBufferWithBytes(waveParametersFloats, length: sizeof(Float)*waveParametersFloats.count, options: [])
        waveProfileParamsBuffer.label = "waveParameters"
        
        return (vertexIn, vertexCount, indexBuffer, indexCount, waveProfileBuffers, waveProfileParamsBuffer, qValues.count)
    }
   
    func drawInMTKView(view: MTKView) {
        do
        {
            //
            // Compute wave profiles and store results in waveProfileBuffers
            //
            let commandBuffer = commandQueue.commandBuffer()
            commandBuffer.label = "Compute command buffer"
            
            if let kpls = kernelPipeLineState
            {
                let waveProfileParamsBufferBytesPerParam = wpParamsBuffer.length / waveProfileBuffers.count
                assert(waveProfileParamsBufferBytesPerParam==256, "Bad paramater buffer alignment")
                var i = 0
                
                for waveProfileBuffer in waveProfileBuffers
                {
                    let commandEncoder: MTLComputeCommandEncoder = commandBuffer.computeCommandEncoder()
                    
                    commandEncoder.setComputePipelineState(kpls)
                    
                    
                    commandEncoder.setBuffer(vertexIn,          offset:0, atIndex: 0)
                    commandEncoder.setBuffer(waveProfileBuffer, offset:0, atIndex: 1)
                    commandEncoder.setBuffer(wpParamsBuffer,    offset:256*i, atIndex: 2)
                    i += 1
                
                        // A one dimensional thread group Swift to pass Metal a one dimensional array
                    let threadGroupWidth = 4
                    let threadgroupsPerGrid = MTLSize(width: threadGroupWidth, height:1, depth:1)
                    let threadsPerThreadgroup = MTLSize(width: vertexCount/threadGroupWidth, height:1, depth:1)
                    
                    commandEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
                    
                    commandEncoder.endEncoding()
                }
                
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                let status = commandBuffer.status
                print("status=\(commandBuffer.status)")
                
                
                //
                // Render wave profiles to screen
                //
                let commandBufferRender = commandQueue.commandBuffer()
                commandBufferRender.label = "Frame command buffer"
                
                if var renderPassDescriptor = view.currentRenderPassDescriptor, currentDrawable = view.currentDrawable
                {
                    var loadActionActual = MTLLoadAction.Clear
                    var renderPassDescriptorActual = renderPassDescriptor
                    let redactedwaveProfileBuffers = waveProfileBuffers.reverse()
                    var constants = Constants()
                    for waveProfileBuffer in redactedwaveProfileBuffers
                    {     
                        // debug stuff          
                        do
                        {
                            let bufferLengthBytes = waveProfileBuffer.length
                            var data = NSData(bytesNoCopy: waveProfileBuffer.contents(),length: bufferLengthBytes, freeWhenDone: false)
                            var datain = NSData(bytesNoCopy: vertexIn.contents(),length: bufferLengthBytes, freeWhenDone: false)
                            var vector_out   : [ProfileCoord] = Array(count: vertexCount, repeatedValue:  ProfileCoord(x:0.0, y:0.0))
                            var vector_inout : [ProfileCoord] = Array(count: vertexCount, repeatedValue:  ProfileCoord(x:0.0, y:0.0))

                            data.getBytes(&vector_out, length:bufferLengthBytes)
                            datain.getBytes(&vector_inout, length:bufferLengthBytes)
                        }
                        
                        // Render stuff
                        renderPassDescriptorActual.colorAttachments[0].loadAction = loadActionActual
//                        renderPassDescriptorActual.colorAttachments[0].storeAction = .Store
                        let renderEncoder = commandBufferRender.renderCommandEncoderWithDescriptor(renderPassDescriptorActual)
                        renderEncoder.label = "render encoder"
                        
                        renderEncoder.pushDebugGroup("draw wave profile")
                        renderEncoder.setCullMode(.None)
                        renderEncoder.setFrontFacingWinding(.Clockwise)
                        
                        renderEncoder.setRenderPipelineState(pipelineState)
                        
                        // Bind the uniform buffer so we can read our model-view-projection matrix in the shader.
                        constants.colour[0] *= 0.8
                        constants.colour[1] *= 0.8
                        constants.offset[3] -= 0.0
                        renderEncoder.setVertexBytes(&constants, length: sizeof(Constants), atIndex: 1)
                        
                        
                        renderEncoder.setVertexBuffer(waveProfileBuffer, offset: 0, atIndex: 0)
                        renderEncoder.drawIndexedPrimitives(.Triangle,
                                                            indexCount: indexCount,
                                                            indexType: .UInt16,
                                                            indexBuffer: indexBuffer,
                                                            indexBufferOffset: 0)
                        
                        renderEncoder.popDebugGroup()
                        renderEncoder.endEncoding()
                        loadActionActual = .Load
                            
                    } // for wave profile buffer
                                    
                    commandBufferRender.presentDrawable(currentDrawable)
                    commandBufferRender.commit()
                    commandBufferRender.waitUntilCompleted()
                } // if render pass descriptor
                
            }
        }
        
        
    }
    
    
    func mtkView(view: MTKView, drawableSizeWillChange size: CGSize) {
        
    }
}
