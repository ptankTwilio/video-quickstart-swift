//
//  ReplayKitVideoSource.swift
//  ReplayKitExample
//
//  Created by Chris Eagleston on 9/30/18.
//  Copyright © 2018 Twilio. All rights reserved.
//

import Accelerate
import CoreMedia
import CoreVideo
import TwilioVideo

class ReplayKitVideoSource: NSObject, TVIVideoCapturer {

    static let kDesiredFrameRate = 30

    public var isScreencast: Bool = false

    // Our capturer attempts to downscale the source to fit in a smaller square, in order to save memory.
    static let kDownScaledMaxWidthOrHeight = 640

    // ReplayKit provides planar NV12 CVPixelBuffers consisting of luma (Y) and chroma (UV) planes.
    static let kYPlane = 0
    static let kUVPlane = 1

    weak var captureConsumer: TVIVideoCaptureConsumer?

    public var supportedFormats: [TVIVideoFormat] {
        get {
            /*
             * Describe the supported format.
             * For this example we cheat and assume that we will be capturing the entire screen.
             */
            let screenSize = UIScreen.main.bounds.size
            let format = TVIVideoFormat()
            format.pixelFormat = TVIPixelFormat.formatYUV420BiPlanarFullRange
            format.frameRate = UInt(ReplayKitVideoSource.kDesiredFrameRate)
            format.dimensions = CMVideoDimensions(width: Int32(screenSize.width), height: Int32(screenSize.height))
            return [format]
        }
    }

    func startCapture(_ format: TVIVideoFormat, consumer: TVIVideoCaptureConsumer) {
        captureConsumer = consumer
        consumer.captureDidStart(true)

        print("Start capturing.")
    }

    func stopCapture() {
        print("Stop capturing.")
    }

    // MARK:- Private
    func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let consumer = self.captureConsumer else {
            return
        }
        guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            assertionFailure("SampleBuffer did not have an ImageBuffer")
            return
        }

        // We only support NV12 (full-range) buffers.
        let pixelFormat = CVPixelBufferGetPixelFormatType(sourcePixelBuffer);
        if (pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            assertionFailure("Extension assumes the incoming frames are of type NV12")
            return
        }

        // Compute the downscaled rect for our destination buffer (in whole pixels).
        // TODO: Do we want to round to even width/height only?
        let rect = AVMakeRect(aspectRatio: CGSize(width: CVPixelBufferGetWidth(sourcePixelBuffer),
                                                  height: CVPixelBufferGetHeight(sourcePixelBuffer)),
                              insideRect: CGRect(x: 0,
                                                 y: 0,
                                                 width: ReplayKitVideoSource.kDownScaledMaxWidthOrHeight,
                                                 height: ReplayKitVideoSource.kDownScaledMaxWidthOrHeight))
        let size = rect.integral.size

        // We will allocate a CVPixelBuffer to hold the downscaled contents.
        // TODO: Consider copying the pixelBufferAttributes to maintain color information. Investigate the color space of the buffers.
        var outPixelBuffer: CVPixelBuffer? = nil
        var status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(size.width),
                                         Int(size.height),
                                         pixelFormat,
                                         nil,
                                         &outPixelBuffer);
        if (status != kCVReturnSuccess) {
            print("Failed to create pixel buffer");
            return
        }

        let destinationPixelBuffer = outPixelBuffer!

        status = CVPixelBufferLockBaseAddress(sourcePixelBuffer, CVPixelBufferLockFlags.readOnly);
        status = CVPixelBufferLockBaseAddress(destinationPixelBuffer, []);

        // Prepare source pointers.
        var sourceImageY = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(sourcePixelBuffer, ReplayKitVideoSource.kYPlane),
                                         height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(sourcePixelBuffer, ReplayKitVideoSource.kYPlane)),
                                         width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(sourcePixelBuffer, ReplayKitVideoSource.kYPlane)),
                                         rowBytes: CVPixelBufferGetBytesPerRowOfPlane(sourcePixelBuffer, ReplayKitVideoSource.kYPlane))

        var sourceImageUV = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(sourcePixelBuffer, ReplayKitVideoSource.kUVPlane),
                                          height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(sourcePixelBuffer, ReplayKitVideoSource.kUVPlane)),
                                          width:vImagePixelCount(CVPixelBufferGetWidthOfPlane(sourcePixelBuffer, ReplayKitVideoSource.kUVPlane)),
                                          rowBytes: CVPixelBufferGetBytesPerRowOfPlane(sourcePixelBuffer, ReplayKitVideoSource.kUVPlane))

        // Prepare destination pointers.
        var destinationImageY = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(destinationPixelBuffer, ReplayKitVideoSource.kYPlane),
                                              height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(destinationPixelBuffer, ReplayKitVideoSource.kYPlane)),
                                              width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(destinationPixelBuffer, ReplayKitVideoSource.kYPlane)),
                                              rowBytes: CVPixelBufferGetBytesPerRowOfPlane(destinationPixelBuffer, ReplayKitVideoSource.kYPlane))

        var destinationImageUV = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(destinationPixelBuffer, ReplayKitVideoSource.kUVPlane),
                                               height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(destinationPixelBuffer, ReplayKitVideoSource.kUVPlane)),
                                               width: vImagePixelCount( CVPixelBufferGetWidthOfPlane(destinationPixelBuffer, ReplayKitVideoSource.kUVPlane)),
                                               rowBytes: CVPixelBufferGetBytesPerRowOfPlane(destinationPixelBuffer, ReplayKitVideoSource.kUVPlane))

        // Scale the Y and UV planes into the destination buffer.
        var error = vImageScale_Planar8(&sourceImageY, &destinationImageY, nil, vImage_Flags(0));
        if (error != kvImageNoError) {
            print("Failed to down scale luma plane.")
            return;
        }

        error = vImageScale_CbCr8(&sourceImageUV, &destinationImageUV, nil, vImage_Flags(0));
        if (error != kvImageNoError) {
            print("Failed to down scale chroma plane.")
            return;
        }

        status = CVPixelBufferUnlockBaseAddress(outPixelBuffer!, [])
        status = CVPixelBufferUnlockBaseAddress(sourcePixelBuffer, [])

        guard let frame = TVIVideoFrame(timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                        buffer: outPixelBuffer!,
                                        orientation: TVIVideoOrientation.up) else {
                                            assertionFailure("We couldn't create a TVIVideoFrame with a valid CVPixelBuffer.")
                                            return
        }
        consumer.consumeCapturedFrame(frame)
    }

}
