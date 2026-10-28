//
//  VideoDecoder.swift
//  iina+
//
//  Created by xjbeta on 2018/10/28.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Cocoa
import Alamofire
import Marshal
import CommonCrypto
import JavaScriptCore
import SwiftSoup

actor VideoDecoder {
    lazy var douyin = DouYin()
    lazy var huya = Huya()
    lazy var douyu = Douyu()
    lazy var cc163 = CC163()
    let bilibili = Bilibili.shared
    lazy var qieTV = QieTV()
	
	let enableDash = false
    
    
    func bilibiliUrlFormatter(_ url: String) async throws -> String {
        let site = SupportSites(url: url)
        
        switch site {
        case .bilibili, .bangumi:
            if url.contains("/festival/"),
               let comps = URLComponents(string: url),
               let bvid = comps.queryItems?.first(where: { $0.name == "bvid" })?.value {
                return "https://www.bilibili.com/video/\(bvid)"
            }
            return BilibiliUrl(url: url)!.fUrl
        case .b23:
			let res = await AF.request(url).serializingData().response
			guard let url = res.response?.url?.absoluteString,
					let u = BilibiliUrl(url: url)?.fUrl else {
				throw VideoGetError.invalidLink
			}
			return u
        default:
            return url
        }
    }
    
    func decodeUrl(_ url: String) async throws -> YouGetJSON {
        switch SupportSites(url: url) {
        case .biliLive:
			try await bilibili.live.decodeUrl(url)
        case .douyu:
			try await douyu.decodeUrl(url)
        case .douyuVod:
			try await douyu.decodeVodUrl(url)
        case .huya:
			try await huya.decodeUrl(url)
        case .bilibili, .bangumi:
            try await bilibili.video.decodeUrl(url)
        case .cc163:
			try await cc163.decodeUrl(url)
        case .douyin:
			try await douyin.decodeUrl(url)
        case .qieTV:
			try await qieTV.decodeUrl(url)
        default:
            throw VideoGetError.notSupported
        }
    }
    
    func liveInfo(_ url: String, _ checkSupport: Bool = true) async throws -> LiveInfo {
        let site = SupportSites(url: url)
        switch site {
        case .biliLive:
			return try await bilibili.live.liveInfo(url)
        case .douyu:
			return try await douyu.liveInfo(url)
        case .douyuVod:
			return try await douyu.vodInfo(url)
        case .huya:
			return try await huya.liveInfo(url)
        case .bilibili, .bangumi:
            return try await bilibili.video.liveInfo(url)
        case .cc163:
			return try await cc163.liveInfo(url)
        case .douyin:
			return try await douyin.liveInfo(url)
        case .qieTV:
			return try await qieTV.liveInfo(url)
        default:
            if checkSupport {
                throw VideoGetError.notSupported
            } else {
                var info = BiliLiveInfo()
                info.isLiving = true
				return info
            }
        }
    }
	
	func prepareDanmakuFile(yougetJSON: YouGetJSON, id: String) async throws {
		let pref = Preferences.shared

		guard await Processes.shared.iina.archiveType != .normal,
			  pref.enableDanmaku,
			  pref.livePlayer == .iina,
			  yougetJSON.id != -1 else {
				  Log("Ignore Danmaku download.")
				  return
		}

		if yougetJSON.site == .douyuVod {
			// 斗鱼回放：把当时直播间的聊天取回来，按时间轴写成弹幕文件交给插件
			guard let hashId = DouyuReplayURL.hashId(from: yougetJSON.rawUrl) else { return }
			let danmaku = try await douyu.replayDanmaku(hashId: hashId)
			guard !danmaku.isEmpty else {
				Log("Douyu replay \(hashId): no danmaku.")
				return
			}
			VideoDecoder.saveDMFile(VideoDecoder.douyuDanmakuXML(danmaku), with: id)
			return
		}

		guard [.bilibili, .bangumi, .local].contains(yougetJSON.site) else {
			Log("Ignore Danmaku download.")
			return
		}

		try await downloadDMFileV2(
			cid: yougetJSON.id,
			length: yougetJSON.duration,
			id: id)
	}

	/// 把斗鱼回放弹幕转成插件（CommentCoreLibrary）能吃的 bilibili XML 格式。
	/// p 字段：时间(秒), 模式, 字号, 颜色(十进制 RGB), 发送时间, 池, 用户 hash, 弹幕 id
	static func douyuDanmakuXML(_ danmaku: [DouyuReplayDanmaku]) -> Data? {
		guard let element = try? XMLElement(xmlString: #"<?xml version="1.0" encoding="UTF-8"?><i><chatserver>chat.bilibili.tv</chatserver><chatid>170102</chatid></i>"#) else {
			return nil
		}
		let doc = XMLDocument(rootElement: element)
		for dm in danmaku {
			let p = ["\(Double(dm.timeMs) / 1000)",
					 "1",			// 模式：滚动
					 "25",			// 字号
					 "\(dm.rgbColor)",
					 "\(dm.date)",
					 "0",			// pool
					 dm.hash,
					 dm.id].joined(separator: ",")
			var text = dm.text
			text = text.replacingOccurrences(of: "<", with: "&lt;")
			text = text.replacingOccurrences(of: ">", with: "&gt;")
			text = text.replacingOccurrences(of: "&", with: "&amp;")
			text = text.replacingOccurrences(of: "'", with: "&apos;")
			text = text.replacingOccurrences(of: "\"", with: "&quot;")
			text = text.replacingOccurrences(of: "`", with: "&apos;")

			if let node = try? XMLElement(xmlString: "<d p=\"\(p)\">\(text)</d>") {
				element.addChild(node)
			}
		}
		return doc.xmlData
	}
	func prepareVideoUrl(_ json: YouGetJSON, _ key: String) async throws -> YouGetJSON {
		
		guard json.id != -1 else {
			return json
		}
		
		switch json.site {
		case .bilibili, .bangumi:
			func registerDash(_ json: YouGetJSON) async -> YouGetJSON {
				guard enableDash,
					  let stream = json.streams[key],
					  let content = stream.dashContent else {
					return json
				}
				var json = json
				json.streams[key]?.dashUrl = await Processes.shared.httpServer.registerDash(json.bvid, content: content)
				return json
			}
			
			guard let stream = json.streams[key],
				  stream.url == "" else {
				return await registerDash(json)
			}
			
			let qn = stream.quality
            let json = try await Bilibili.shared.bilibiliPlayUrl(yougetJson: json, json.site == .bangumi, qn)
			return await registerDash(json)
		case .biliLive:
			guard let stream = json.streams[key],
				  stream.quality != -1 else {
				return json
			}
			let qn = stream.quality
			
			if let url = stream.url,
			   url != "" {
				return json
			} else {
				var re = try await bilibili.live.getBiliLiveJSON(json, qn, with: .roomPlayInfo)
				
				func results() -> YouGetJSON? {
					if let stream = re.streams[key],
					   let url = stream.url,
					   url != "" {
						return re
					} else {
						return nil
					}
				}
				
				if let re = results() {
					return re
				}
				
				re = try await bilibili.live.getBiliLiveJSON(json, qn, with: .playUrl)
				
				if let re = results() {
					return re
				}
				
				throw VideoGetError.needLogin
			}
		case .douyu:
			guard let stream = json.streams[key],
				  stream.quality != -1 else {
				return json
			}
			let rate = stream.rate
			if stream.url != "" {
				return json
			} else {
				let id = json.id
				let html = try await douyu.getDouyuHtml("https://www.douyu.com/\(id)")
				let urls = try await douyu.getDouyuUrl(id, rate: rate)
				let url = urls.first {
					$0.1.rate == rate
				}?.1.url
				var re = json
				re.streams[key]?.url = url
				return re
			}
		case .douyuVod:
			// 播放地址已是本地回放列表地址；这里只补上续播/存位参数。
			// watch_later 是按播放列表里的「条目地址」记账的（不是列表地址），
			// 所以进度要绑在分P自己的那条稳定地址上。
			guard let stream = json.streams[key],
				  let hashId = DouyuReplayURL.hashId(from: json.rawUrl) else {
				return json
			}
			let itemURL = DouyuReplayURL.stream(hashId: hashId, level: stream.quality)
			let options = await ReplayProgressStore.shared.beginPlayback(id: hashId, url: itemURL)
			var re = json
			re.extraMpvOptions = options
			return re
		default:
			return json
		}
	}
}



extension VideoDecoder {
    
    // MARK: - Bilibili Danmaku
    func downloadDMFile(_ cid: Int, id: String) async throws {
		let data = try await AF.request("https://comment.bilibili.com/\(cid).xml").serializingData().value
		VideoDecoder.saveDMFile(data, with: id)
    }
    
    
    func downloadDMFileV2(cid: Int, length: Int, id: String) async throws {
        
//        segment_index  6min
        
        let c = Int(ceil(Double(length) / 360))
        let s = c > 1 ? Array(1...c) : [1]
        
        print("downloadDMFileV2", c)
        
        guard c < 1500 else {
            return
        }
		
		let dms = try await withThrowingTaskGroup(of: [DanmakuElem].self) { group in
			for i in s {
				group.addTask {
					try await self.getDanmakuContent(cid: cid, index: i)
				}
			}
			
			var re = [DanmakuElem]()
			
			for try await e in group {
				re.append(contentsOf: e)
			}
			
			return re
		}
		
		let element = try XMLElement(xmlString: #"<?xml version="1.0" encoding="UTF-8"?><i><chatserver>chat.bilibili.tv</chatserver><chatid>170102</chatid></i>"#)
		
		let doc = XMLDocument(rootElement: element)
		
		dms.map { dm -> String in
			let s1 = ["\(Double(dm.progress) / 1000)",
					  "\(dm.mode)",
					  "\(dm.fontsize)",
					  "\(dm.color)",
					  "\(dm.ctime)",
					  "\(dm.pool)",
					  "\(dm.midHash)",
					  "\(dm.id)"].joined(separator: ",")
			var s2 = dm.content
			
			s2 = s2.replacingOccurrences(of: "<", with: "&lt;")
			s2 = s2.replacingOccurrences(of: ">", with: "&gt;")
			s2 = s2.replacingOccurrences(of: "&", with: "&amp;")
			s2 = s2.replacingOccurrences(of: "'", with: "&apos;")
			s2 = s2.replacingOccurrences(of: "\"", with: "&quot;")
			
			s2 = s2.replacingOccurrences(of: "`", with: "&apos;")
			
			return "<d p=\"\(s1)\">\(s2)</d>"
		}.forEach {
			if let node = try? XMLElement(xmlString: $0) {
				element.addChild(node)
			} else {
				Log("Invalid Bangumi Line: \($0)")
			}
		}
		
		VideoDecoder.saveDMFile(doc.xmlData, with: id)
    }
    
    static func saveDMFile(_ data: Data?, with id: String) {
		guard let path = VideoDecoder.dmPath(id) else { return }
        var p = path
        p.deleteLastPathComponent()
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: data, attributes: nil)
        Log("Saved DM in \(path)")
    }
    
    static func dmPath(_ id: String) -> String? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
            var filesURL = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        let folderName = "WebFiles"
        
        filesURL.appendPathComponent(bundleIdentifier)
        filesURL.appendPathComponent(folderName)
        let fileName = "danmaku" + "-" + id + ".xml"
        
        filesURL.appendPathComponent(fileName)
        return filesURL.path
    }
    
    func getDanmakuContent(cid: Int, index: Int) async throws -> [DanmakuElem] {
		let u = "https://api.bilibili.com/x/v2/dm/web/seg.so?type=1&oid=\(cid)&segment_index=\(index)"
		
		let data = try await AF.request(u).serializingData().value
		return try DmSegMobileReply(serializedBytes: data).elems
    }
}

enum VideoGetError: Error {
    case invalidLink
    
    case douyuUrlError
    case douyuSignError
    case douyuNotFoundRoomId
    case douyuNotFoundSubRooms
    case douyuRoomIdsCountError
    case douyuReplayEmpty
    case douyuReplayFailed(String)
    
    case isNotLiving
    case notFindUrls
    case notSupported
    
    case cantFindIdForDM
    
    case prepareDMFailed
    
    case cantWatch
    case notFountData
    case needVip
	case needLogin
    case needPassWork
}
