//
//  ReplayCacheView.swift
//  IINA+
//
//  回放缓存管理：列表（状态/大小）、开始缓存、播放本地缓存、删除/清空。
//

import SwiftUI

struct ReplayCacheView: View {
	/// 从回放列表右键带过来的待缓存目标；为 nil 时只做管理。
	struct Pending: Identifiable {
		let id = UUID()
		var sessionTitle: String
		var parts: [PendingPart]
	}

	struct PendingPart: Codable, Sendable {
		var hashId: String
		var partNum: Int
		var durationSecs: Int
		var title: String
	}

	struct QualityOption: Identifiable, Equatable {
		var id: Int { level }
		var name: String
		var level: Int
	}

	let pending: Pending?
	let onClose: () -> Void

	@State private var items: [ReplayDownloadManager.Item] = []
	@State private var options: [QualityOption] = []
	@State private var selectedLevel: Int = 0
	@State private var loadingOptions = false
	@State private var totalSize: Int64 = 0
	@State private var confirmingClear = false

	private let refreshPublisher = NotificationCenter.default
		.publisher(for: .replayCacheChanged)
		.receive(on: DispatchQueue.main)

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			if let pending {
				pendingSection(pending)
			}
			if !items.isEmpty {
				listSection
			} else {
				Text(NSLocalizedString("ReplayCache.Empty", comment: "empty cache"))
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .center)
					.padding(.vertical, 18)
			}
			footer
		}
		.padding(14)
		.frame(minWidth: 460, minHeight: 320)
		.task { await refresh() }
		.onReceive(refreshPublisher) { _ in
			Task { await refresh() }
		}
	}

	// MARK: 待缓存

	@ViewBuilder
	private func pendingSection(_ pending: Pending) -> some View {
		GroupBox {
			HStack(spacing: 10) {
				VStack(alignment: .leading, spacing: 2) {
					Text(pending.parts.count == 1 ? pending.parts[0].title : pending.sessionTitle)
						.font(.headline)
						.lineLimit(1)
					if pending.parts.count > 1 {
						Text(String(format: NSLocalizedString("ReplayCache.CacheSession", comment: ""),
									pending.parts.count)
							 + " · " + pending.parts.map { "P\($0.partNum)" }.joined(separator: " "))
							.font(.caption)
							.foregroundStyle(.secondary)
							.lineLimit(1)
					} else {
						Text(pending.sessionTitle)
							.font(.caption)
							.foregroundStyle(.secondary)
							.lineLimit(1)
					}
				}
				Spacer()
				if loadingOptions {
					ProgressView()
						.controlSize(.small)
				} else if options.isEmpty {
					Text(NSLocalizedString("ReplayCache.NoQuality", comment: "no quality"))
						.foregroundStyle(.secondary)
				} else {
					Picker("", selection: $selectedLevel) {
						ForEach(options) { option in
							Text(option.name).tag(option.level)
						}
					}
					.labelsHidden()
					.frame(width: 150)
					Button(NSLocalizedString("ReplayCache.Start", comment: "Start")) {
						Task { await startPending() }
					}
					.disabled(!options.contains { $0.level == selectedLevel })
				}
			}
			.padding(2)
		}
	}

	// MARK: 列表

	private var listSection: some View {
		ScrollView {
			VStack(spacing: 8) {
				ForEach(items, id: \.id) { item in
					row(item)
				}
			}
			.padding(.vertical, 2)
		}
	}

	private func row(_ item: ReplayDownloadManager.Item) -> some View {
		HStack(alignment: .top, spacing: 10) {
			VStack(alignment: .leading, spacing: 2) {
				Text("\(item.sessionTitle) · P\(item.partNum) [\(item.levelName)]")
					.font(.headline)
					.lineLimit(1)
				switch item.state {
				case .downloading:
					if item.totalSegments > 0 {
						ProgressView(value: Double(item.downloadedSegments), total: Double(item.totalSegments))
							.progressViewStyle(.linear)
							.tint(.accentColor)
						Text(String(format: NSLocalizedString("ReplayCache.Downloading", comment: "downloading %d%%"),
									Int(Double(item.downloadedSegments) / Double(max(item.totalSegments, 1)) * 100))
							 + " · " + ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
							.font(.caption)
							.foregroundStyle(.secondary)
					} else {
						Text(NSLocalizedString("ReplayCache.Preparing", comment: "preparing"))
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				case .done:
					Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
						.font(.caption)
						.foregroundStyle(.secondary)
				case .failed:
					Text(NSLocalizedString("ReplayCache.Failed", comment: "failed"))
						.font(.caption)
						.foregroundStyle(.red)
				}
			}
			Spacer()
			VStack(spacing: 6) {
				if item.state == .done {
					Button(NSLocalizedString("ReplayCache.Play", comment: "Play")) {
						Task { await play(item) }
					}
					.controlSize(.small)
				}
				Button(NSLocalizedString("ReplayCache.Delete", comment: "Delete")) {
					Task {
						await ReplayDownloadManager.shared.delete(id: item.id)
						await refresh()
					}
				}
				.controlSize(.small)
			}
		}
		.padding(.vertical, 4)
	}

	private var footer: some View {
		HStack {
			Text(String(format: NSLocalizedString("ReplayCache.Total", comment: "total %@"), ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)))
				.font(.caption)
				.foregroundStyle(.secondary)
			Spacer()
			if !items.isEmpty {
				Button(confirmingClear
					   ? NSLocalizedString("ReplayCache.ConfirmClear", comment: "confirm clear")
					   : NSLocalizedString("ReplayCache.ClearAll", comment: "clear all")) {
					if confirmingClear {
						Task {
							await ReplayDownloadManager.shared.clearAll()
							await refresh()
							confirmingClear = false
						}
					} else {
						confirmingClear = true
					}
				}
				.controlSize(.small)
			}
			Button(NSLocalizedString("ReplayCache.Close", comment: "Close")) { onClose() }
				.keyboardShortcut(.cancelAction)
		}
	}

	// MARK: 动作

	private func refresh() async {
		items = await ReplayDownloadManager.shared.items()
		totalSize = items.reduce(0) { $0 + $1.bytes }
		guard let pending, options.isEmpty, !loadingOptions, let first = pending.parts.first else { return }
		loadingOptions = true
		defer { loadingOptions = false }
		do {
			let douyu = await Processes.shared.videoDecoder.douyu
			let qualities = try await douyu.replayQualities(hashId: first.hashId)
			options = qualities.map { QualityOption(name: $0.name, level: $0.level) }
			selectedLevel = options.first?.level ?? 0
		} catch {
			options = []
			Log("Replay cache: qualities fetch failed \(error)")
		}
	}

	private func startPending() async {
		guard let pending,
			  let option = options.first(where: { $0.level == selectedLevel }) else { return }
		for part in pending.parts {
			await ReplayDownloadManager.shared.start(ReplayDownloadManager.Request(
				hashId: part.hashId,
				level: option.level,
				levelName: option.name,
				partNum: part.partNum,
				title: part.title,
				sessionTitle: pending.sessionTitle,
				durationSecs: part.durationSecs))
		}
		await refresh()
	}

	private func play(_ item: ReplayDownloadManager.Item) async {
		await MainActor.run {
			var json = YouGetJSON(url: item.filePath)
			json.site = .local
			json.title = item.title
			guard let key = json.videos.max(by: { $0.value.quality < $1.value.quality })?.key else { return }
			Task {
				try? await Processes.shared.openWithPlayer(json, key)
			}
		}
	}
}
