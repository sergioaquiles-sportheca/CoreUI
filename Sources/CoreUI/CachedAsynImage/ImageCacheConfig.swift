//
//  ImageCacheConfig.swift
//  CoreUI
//
//  Created by Sergio Cardoso on 22/10/25.
//

import Foundation

public struct ImageCacheConfig {
    public var timeToLive: TimeInterval
    public var maxDiskBytes: Int
    public var nameSpace: String
    
    public init(
        timeToLive: TimeInterval = 7 * 24 * 60 * 60, // seven days
        maxDiskBytes: Int = 200 * 1024 * 1024, // 200MB
        nameSpace: String = "ImageCache"
    ) {
        self.timeToLive = timeToLive
        self.maxDiskBytes = maxDiskBytes
        self.nameSpace = nameSpace
    }
}
