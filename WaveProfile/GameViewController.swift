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
    
    var commandQueue:       MTLCommandQueue! = nil
    var commandQueueKernel: MTLCommandQueue! = nil
    var pipelineState:       MTLRenderPipelineState! = nil
    var kernelPipeLineState: MTLComputePipelineState! = nil
    var vertexIn:       MTLBuffer! = nil
    var indexBuffer:    MTLBuffer! = nil
    var wpParamsBuffer: MTLBuffer! = nil
    var waveProfileBuffers:     [MTLBuffer]! = nil
    var vertexCount:      Int = 0
    var indexCount:       Int = 0
    var waveProfileCount: Int = 0
    
    let inflightSemaphore = DispatchSemaphore(value: MaxBuffers)
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
        let profile_buffers = createProfileBuffers(device)
        vertexIn           = profile_buffers.vertexIn
        vertexCount        = profile_buffers.vertexCount
        indexBuffer        = profile_buffers.indexBuffer
        indexCount         = profile_buffers.indexCount
        waveProfileBuffers = profile_buffers.waveProfileBuffers
        wpParamsBuffer     = profile_buffers.wpParamsBuffer
        waveProfileCount   = profile_buffers.waveProfileCount
        
    }
    
    func loadAssets() {
        
        // load any resources required for rendering
        let view = self.view as! MTKView
        commandQueue = device.makeCommandQueue()
        commandQueue.label = "main command queue"
        
        commandQueueKernel = device.makeCommandQueue()
        commandQueueKernel.label = "kernel command queue"
        
        // Get draw shaders
        let defaultLibrary = device.newDefaultLibrary()!
        let fragmentProgram = defaultLibrary.makeFunction(name: "passThroughFragment")!
        let vertexProgram   = defaultLibrary.makeFunction(name: "passThroughVertex")!
        
        // Setup pipeline descriptor for drawing
        let pipelineStateDescriptor = MTLRenderPipelineDescriptor()
        pipelineStateDescriptor.vertexFunction                  = vertexProgram
        pipelineStateDescriptor.fragmentFunction                = fragmentProgram
        pipelineStateDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineStateDescriptor.sampleCount                     = view.sampleCount
        
        do {
            try pipelineState = device.makeRenderPipelineState(descriptor: pipelineStateDescriptor)
        } catch let error {
            print("Failed to create pipeline state, error \(error)")
        }
                
        if let kernelProfileFunction = defaultLibrary.makeFunction(name: "profileKernel")
        {
            kernelPipeLineState = try? device.makeComputePipelineState(function: kernelProfileFunction)
        }
    }
 
    // Create a vertex buffer and its associated index buffer for input into a compute metal shader.
    // The vertexes have incrementing x values from the left side to the right side of the screen (i.e. -1.0 to +1.0)
    // with the y values alternating between top (1.0) and bottom (-1.0).  There is no z value.
    // The indexes are setup to create a triangle mesh.
    func createWaveProfileInputBuffer(_ device : MTLDevice) -> (vertexIn: MTLBuffer, vertexCount:Int, indexBuffer: MTLBuffer, indexCount:Int)
    {
        var vector : [ProfileCoord] = [ ]
        var indexes : [UInt16] = []
        let NUM_POINTS = 512
        
        vector.reserveCapacity(NUM_POINTS)
        for i in 0..<NUM_POINTS
        {
            let xx = 2.0 * (Float(i) / Float(NUM_POINTS-1)) - 1.0
            vector +=  [ ProfileCoord(x:xx, y:1.0), ProfileCoord(x:xx, y: -1.0) ]
            
            // indexes for counter clock wise triangles, referencing the current x value an the previous x values.
            if i > 0
            {
                let a = UInt16(2*(i-1))
                let b = a+1
                let c = b+1
                let d = c+1
                indexes += [ a, c, b, c, d, b]
            }
        }
        
        let bufferLengthBytes = vector.count*MemoryLayout<ProfileCoord>.size
        let inBuffer = device.makeBuffer(bytes: vector, length: bufferLengthBytes, options: [])
        inBuffer.label = "in"
        
        let indexBuffer = device.makeBuffer(bytes: indexes, length: indexes.count * MemoryLayout<UInt16>.size, options: [])
        indexBuffer.label = "index buffer"
        
        return (vertexIn: inBuffer, vertexCount:vector.count, indexBuffer: indexBuffer, indexCount: indexes.count)
    }
    
    // Create metal buffers for generating wave profiles.
    // One set of buffers for each hardwired Q value. (The Q value determines the shape of the wave profile)
    func createProfileBuffers(_ device : MTLDevice) -> ( 
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

        let paramsBufferFloatsPerSet = 256 / MemoryLayout<Float>.size
        var waveParametersFloats = [Float](repeating: 0.0, count: paramsBufferFloatsPerSet * qValues.count)
        var waveProfileBuffers : [MTLBuffer] = []
        let bufferLengthBytes = vertexCount * MemoryLayout<ProfileCoord>.size
                
        for (i,q) in qValues.enumerated()
        {
            // For each q value create a set of parameters to tell the compute shader 
            // These need to be aligned to 256 byte boundaries, for use with commandEncoder.setBuffer().
            let wp = WaveParams(Qbase: q, amplitude: 0.2, height: -0.5+1.6*q)
            waveParametersFloats[paramsBufferFloatsPerSet*i + 0] = wp.Qbase
            waveParametersFloats[paramsBufferFloatsPerSet*i + 1] = wp.amplitude
            waveParametersFloats[paramsBufferFloatsPerSet*i + 2] = wp.height //

            // create a metal buffer for the output of the compute shader and the input of the draw shader.
            waveProfileBuffers += [ device.makeBuffer(length: bufferLengthBytes, options: []) ]            
        }
        let waveProfileParamsBuffer = device.makeBuffer(bytes: waveParametersFloats, length: MemoryLayout<Float>.size*waveParametersFloats.count, options: [])
        waveProfileParamsBuffer.label = "waveParameters"
        
        return (vertexIn, vertexCount, indexBuffer, indexCount, waveProfileBuffers, waveProfileParamsBuffer, qValues.count)
    }
   
    func draw(in view: MTKView) {
        do
        {
            //
            // Compute wave profiles and store results in waveProfileBuffers
            // this is done once per draw that not efficient since at the moment non of the parameters change.
            let commandBuffer = commandQueue.makeCommandBuffer()
            commandBuffer.label = "Compute command buffer"
            
            if let kpls = kernelPipeLineState
            {
                let waveProfileParamsBufferBytesPerParam = wpParamsBuffer.length / waveProfileBuffers.count
                assert(waveProfileParamsBufferBytesPerParam==256, "Bad paramater buffer alignment")
                
                // Iterate though the to be computed profile vertex buffers, one per Q value
                // with i indexing the parameters for that wave profile.
                // and add the to the compute command queue.
                for (i, waveProfileBuffer) in waveProfileBuffers.enumerated()
                {
                    let commandEncoder: MTLComputeCommandEncoder = commandBuffer.makeComputeCommandEncoder()
                    
                    commandEncoder.setComputePipelineState(kpls)
                                        
                    commandEncoder.setBuffer(vertexIn,          offset:0, at: 0)
                    commandEncoder.setBuffer(waveProfileBuffer, offset:0, at: 1)
                    commandEncoder.setBuffer(wpParamsBuffer,    offset:256*i, at: 2)
               
                    // A one dimensional thread group Swift to pass Metal a one dimensional array
                    let threadGroupWidth = 4
                    let threadgroupsPerGrid = MTLSize(width: threadGroupWidth, height:1, depth:1)
                    let threadsPerThreadgroup = MTLSize(width: vertexCount/threadGroupWidth, height:1, depth:1)
                    
                    commandEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
                    
                    commandEncoder.endEncoding()
                }
                
                // Kick off the compute jobs.
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                let status = commandBuffer.status
                if status != .completed
                {
                    print("\(commandBuffer.label) status=\(commandBuffer.status.rawValue)")
                }
                                
                //
                // Render wave profiles to screen
                //
                let commandBufferRender = commandQueue.makeCommandBuffer()
                commandBufferRender.label = "Frame command buffer"
                
                if var renderPassDescriptor = view.currentRenderPassDescriptor, var currentDrawable = view.currentDrawable
                {
                    var loadActionActual = MTLLoadAction.clear
                    var renderPassDescriptorActual = renderPassDescriptor
                    let redactedwaveProfileBuffers = waveProfileBuffers.reversed()
                    var constants = Constants()  // Uniform values

                    for waveProfileBuffer in redactedwaveProfileBuffers
                    {     
                        // debug stuff          
                        do
                        {
                            let bufferLengthBytes = waveProfileBuffer.length
                            var data   = Data(bytesNoCopy: waveProfileBuffer.contents(),count: bufferLengthBytes, deallocator: .none)
                            var datain = Data(bytesNoCopy: vertexIn.contents(),count: bufferLengthBytes, deallocator: .none)
                            var vector_out   : [ProfileCoord] = Array(repeating: ProfileCoord(x:0.0, y:0.0), count: vertexCount)
                            var vector_inout : [ProfileCoord] = Array(repeating: ProfileCoord(x:0.0, y:0.0), count: vertexCount)

                            (data as NSData).getBytes(&vector_out, length:bufferLengthBytes)
                            (datain as NSData).getBytes(&vector_inout, length:bufferLengthBytes)
                        }
                        
                        // Render stuff
                        renderPassDescriptorActual.colorAttachments[0].loadAction = loadActionActual
//                        renderPassDescriptorActual.colorAttachments[0].storeAction = .Store
                        let renderEncoder = commandBufferRender.makeRenderCommandEncoder(descriptor: renderPassDescriptorActual)
                        renderEncoder.label = "render encoder"
                        
                        renderEncoder.pushDebugGroup("draw wave profile")
                        renderEncoder.setCullMode(.none)
                        renderEncoder.setFrontFacing(.clockwise)
                        
                        renderEncoder.setRenderPipelineState(pipelineState)
                        
                        // Bind the uniform buffer. constants starts with colour being pure white, make it cumulatively darker for each wave.
                        constants.colour[0] *= 0.8
                        constants.colour[1] *= 0.8
                        constants.offset[3] -= 0.0
                        renderEncoder.setVertexBytes(&constants, length: MemoryLayout<Constants>.size, at: 1)
                        
                        
                        renderEncoder.setVertexBuffer(waveProfileBuffer, offset: 0, at: 0)
                        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                            indexCount: indexCount,
                                                            indexType: .uint16,
                                                            indexBuffer: indexBuffer,
                                                            indexBufferOffset: 0)
                        
                        renderEncoder.popDebugGroup()
                        renderEncoder.endEncoding()
                        loadActionActual = .load
                            
                    } // for wave profile buffer
                                    
                    commandBufferRender.present(currentDrawable)
                    commandBufferRender.commit()
                    commandBufferRender.waitUntilCompleted()
                } // if render pass descriptor
                
            }
        }
        
        
    }
    
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        
    }
}
