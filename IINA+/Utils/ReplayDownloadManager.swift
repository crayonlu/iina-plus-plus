//
//  ReplayDownloadManager.swift
//  IINA+
//
//  斗鱼回放缓存：把某个分P按指定档位下载成单个 .ts 文件。
//
//  分片直接从 CDN 拉（地址由 DouyuReplay.replaySegmentURLs 现签），写到
//  work/<id>/seg-NNNN.ts，全部完成后按顺序拼成 <标题>.ts。分片按文件落盘
//  是为了断点续传：重新开始时跳过已存在的分片继续。
//

import Foundation

/// 回放缓存下载管理。
actor ReplayDownloadManager {
	static let shared = ReplayDownloadManager()

	struct Item: Codable, Sendable {
		enum State: String, Codable, Sendable {
			case downloading
			case done
			case failed
		}

		var id: String
		var hashId: String
		var level: Int
		var levelName: String
		var partNum: Int
		var title: String
		var sessionTitle: String
		var durationSecs: Int
		var createdAt: Date
		var state: State = .downloading
		var downloadedSegments = 0
		var totalSegments = 0
		var bytes: Int64 = 0
		var filePath = ""
		var message = ""
	}

	struct Request: Sendable {
		var hashId: String
		var level: Int
		var levelName: String
		var partNum: Int
		var title: String
		var sessionTitle: String
		var durationSecs: Int
	}

	// MARK: - 存储

	static var cacheDirectory: URL {
		let base = try? FileManager.default.url(for: .applicationSupportDirectory,
												in: .userDomainMask,
												appropriateFor: nil,
												create: false)
		let bundle = Bundle.main.bundleIdentifier ?? "com.xjbeta.iina-plus"
		return (base ?? FileManager.default.temporaryDirectory)
			.appendingPathComponent(bundle, isDirectory: true)
			.appendingPathComponent("ReplayCache", isDirectory: true)
	}

	private var indexURL: URL {
		Self.cacheDirectory.appendingPathComponent("index.json")
	}

	private var store: [String: Item]
	private var running: Set<String> = []
	private var cancelled: Set<String> = []

	private init() {
		var decoded: [String: Item] = [:]
		if let data = try? Data(contentsOf: Self.cacheDirectory.appendingPathComponent("index.json")),
		   let loaded = try? JSONDecoder().decode([String: Item].self, from: data) {
			decoded = loaded
		}
		// 上次没下完的：标记为失败但保留分片，重新开始时续传
		for (id, item) in decoded where item.state == .downloading {
			decoded[id]?.state = .failed
			decoded[id]?.message = NSLocalizedString("ReplayCache.Interrupted", comment: "interrupted")
		}
		store = decoded
		if store.values.contains(where: { $0.state == .failed }) {
			Self.writeIndex(store)
		}
	}

	// MARK: - 对外接口

	/// 开始缓存一个分P；已在缓存或已在下载时什么都不做。
	func start(_ request: Request) {
		let id = Self.identifier(hashId: request.hashId, level: request.level)
		guard store[id] == nil, !running.contains(id) else { return }

		store[id] = Item(id: id,
						 hashId: request.hashId,
						 level: request.level,
						 levelName: request.levelName,
						 partNum: request.partNum,
						 title: request.title,
						 sessionTitle: request.sessionTitle,
						 durationSecs: request.durationSecs,
						 createdAt: Date())
		writeIndex(store)
		notify()
		running.insert(id)

		Task {
			await run(id: id)
			running.remove(id)
		}
	}

	func cancel(id: String) {
		cancelled.insert(id)
	}

	func items() -> [Item] {
		store.values.sorted { $0.createdAt > $1.createdAt }
	}

	/// 删除一条缓存（含正在下载的）。
	func delete(id: String) {
		cancelled.insert(id)
		if let item = store[id] {
			try? FileManager.default.removeItem(at: Self.fileURL(for: item))
			try? FileManager.default.removeItem(at: Self.workDirectory(for: item))
		}
		store[id] = nil
		writeIndex(store)
		notify()
	}

	func clearAll() {
		for item in store.values {
			cancelled.insert(item.id)
			try? FileManager.default.removeItem(at: Self.fileURL(for: item))
			try? FileManager.default.removeItem(at: Self.workDirectory(for: item))
		}
		store.removeAll()
		writeIndex(store)
		notify()
	}

	// MARK: - 下载编排（actor 侧）

	private func run(id: String) async {
		guard var item = store[id] else { return }
		let douyu = await Processes.shared.videoDecoder.douyu
		do {
			let workDir = Self.workDirectory(for: item)
			try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

			let segments = try await douyu.replaySegmentURLs(hashId: item.hashId, level: item.level)
			item.totalSegments = segments.count
			store[id] = item
			notify()

			let completed = try await Self.performDownload(segments: segments,
														   workDir: workDir,
														   item: item,
														   douyu: douyu,
														   progress: { [weak self] done, bytes in
															   await self?.reportProgress(id: id, segments: done, bytes: bytes)
														   },
														   cancelled: { [weak self] in
															   await self?.isCancelled(id: id) ?? true
														   })
			guard completed >= segments.count else {
				throw ReplayCacheError.incomplete
			}

			let target = Self.fileURL(for: item)
			try Self.concatenate(segments: Array(0..<segments.count), workDir: workDir, to: target)
			try? FileManager.default.removeItem(at: workDir)

			item.state = .done
			item.filePath = target.path
			if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64 {
				item.bytes = size
			}
			store[id] = item
			writeIndex(store)
			notify()
		} catch ReplayCacheError.cancelled {
			store[id] = nil
			writeIndex(store)
			try? FileManager.default.removeItem(at: Self.workDirectory(for: item))
			notify()
		} catch ReplayCacheError.incomplete {
			item.state = .failed
			item.message = NSLocalizedString("ReplayCache.Incomplete", comment: "incomplete")
			store[id] = item
			writeIndex(store)
			notify()
		} catch {
			item.state = .failed
			item.message = String(describing: error)
			store[id] = item
			writeIndex(store)
			notify()
		}
	}

	private func reportProgress(id: String, segments: Int, bytes: Int64) {
		guard store[id] != nil else { return }
		store[id]?.downloadedSegments = segments
		store[id]?.bytes = bytes
		writeIndex(store)
		notify()
	}

	private func isCancelled(id: String) -> Bool {
		cancelled.contains(id) || store[id] == nil
	}

	// MARK: - 下载执行（nonisolated：不碰 actor 状态，进度/取消走回调）

	/// 下载全部分片，返回完成的分片数；取消时抛 ReplayCacheError.cancelled。
	private static func performDownload(segments: [String],
										workDir: URL,
										item: Item,
										douyu: Douyu,
										progress: @escaping @Sendable (Int, Int64) async -> Void,
										cancelled: @escaping @Sendable () async -> Bool) async throws -> Int {
		let concurrency = 3
		var next = 0
		var runningCount = 0
		var completed = 0
		var downloadedBytes: Int64 = 0

		await withTaskGroup(of: Int?.self) { group in
			func addTask() {
				let index = next
				next += 1
				runningCount += 1
				group.addTask { [segments, item] in
					await Self.downloadSegment(segments,
											   index: index,
											   workDir: workDir,
											   item: item,
											   douyu: douyu,
											   cancelled: cancelled)
				}
			}
			while next < segments.count, runningCount < concurrency {
				addTask()
			}
			while let finished = await group.next() {
				runningCount -= 1
				if let finished {
					completed += 1
					if let data = try? Data(contentsOf: workDir.appendingPathComponent(segmentName(finished))) {
						downloadedBytes += Int64(data.count)
					}
					await progress(completed, downloadedBytes)
				}
				guard !(await cancelled()) else {
					group.cancelAll()
					break
				}
				if next < segments.count {
					addTask()
				}
			}
		}

		guard !(await cancelled()) else { throw ReplayCacheError.cancelled }
		guard completed >= segments.count else { throw ReplayCacheError.incomplete }
		return completed
	}

	/// 下载单个分片（带重签重试）；成功返回该分片下标。
	private static func downloadSegment(_ segments: [String],
										index: Int,
										workDir: URL,
										item: Item,
										douyu: Douyu,
										cancelled: @escaping @Sendable () async -> Bool) async -> Int? {
		let target = workDir.appendingPathComponent(segmentName(index))
		if FileManager.default.fileExists(atPath: target.path) {
			return index    // 续传：已存在的分片跳过
		}
		var current = segments
		for attempt in 0..<3 {
			if await cancelled() { return nil }
			do {
				let data = try await fetch(current[index])
				guard !data.isEmpty else { throw ReplayCacheError.badResponse }
				try data.write(to: target, options: .atomic)
				return index
			} catch {
				if await cancelled() { return nil }
				// 签名/地址过期：重新签一份分片列表再试同一分片
				if attempt < 2,
				   let fresh = try? await douyu.replaySegmentURLs(hashId: item.hashId, level: item.level),
				   fresh.count == current.count {
					current = fresh
				}
				try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (attempt + 1)))
			}
		}
		return nil
	}

	private static func fetch(_ url: String) async throws -> Data {
		guard let u = URL(string: url) else { throw ReplayCacheError.badResponse }
		var request = URLRequest(url: u)
		request.timeoutInterval = 60
		let (data, _) = try await URLSession.shared.data(for: request)
		return data
	}

	// MARK: - 工具

	static func identifier(hashId: String, level: Int) -> String {
		"\(hashId)@\(level)"
	}

	private static func segmentName(_ index: Int) -> String {
		String(format: "seg-%05d.ts", index)
	}

	static func workDirectory(for item: Item) -> URL {
		cacheDirectory.appendingPathComponent("work", isDirectory: true)
			.appendingPathComponent(item.id, isDirectory: true)
	}

	static func fileURL(for item: Item) -> URL {
		let base = sanitize("\(item.sessionTitle) P\(item.partNum) [\(item.levelName)]")
		return cacheDirectory.appendingPathComponent(base + ".ts")
	}

	private static func sanitize(_ name: String) -> String {
		let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
		let cleaned = name.components(separatedBy: invalid).joined(separator: " ")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return cleaned.isEmpty ? "replay" : String(cleaned.prefix(120))
	}

	private static func concatenate(segments: [Int], workDir: URL, to target: URL) throws {
		FileManager.default.createFile(atPath: target.path, contents: nil)
		let output = try FileHandle(forWritingTo: target)
		defer { try? output.close() }
		for index in segments {
			let file = workDir.appendingPathComponent(segmentName(index))
			guard let handle = try? FileHandle(forReadingFrom: file) else {
				throw ReplayCacheError.incomplete
			}
			defer { try? handle.close() }
			while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
				try? output.write(contentsOf: chunk)
			}
		}
	}

	nonisolated private static func writeIndex(_ items: [String: Item]) {
		try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
		guard let data = try? JSONEncoder().encode(items) else { return }
		try? data.write(to: cacheDirectory.appendingPathComponent("index.json"), options: .atomic)
	}

	private func writeIndex(_ items: [String: Item]) {
		Self.writeIndex(items)
	}

	private func notify() {
		NotificationCenter.default.post(name: .replayCacheChanged, object: nil)
	}
}

enum ReplayCacheError: Error {
	case cancelled
	case incomplete
	case badResponse
}
