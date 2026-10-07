//
//  SelectVideoViewController.swift
//  iina+
//
//  Created by xjbeta on 2018/8/21.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Cocoa

class SelectVideoViewController: NSViewController {

    @IBOutlet var outlineView: NSOutlineView!
    var currentItem = 0 {
        didSet {
            guard oldValue != currentItem else { return }
            rootItems = buildRootItems()
            outlineView.reloadData()
            expandDefault()
        }
    }

    private var rootItems: [VideoTreeNode] = []

    var videoTreeNodes: [VideoTreeNode] = [] {
        didSet {
            videoInfos = videoTreeNodes.flattened
        }
    }

    private var videoInfos: [VideoTreeNode] = [] {
        didSet {
            rootItems = buildRootItems()
            outlineView.reloadData()
            expandDefault()
        }
    }

    var videoId = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        setupReplayCacheMenu()
    }

    private func buildRootItems() -> [VideoTreeNode] {
        var items: [VideoTreeNode] = []
        if currentItem > 0, currentItem < leafItems.count {
            items.append(leafItems[currentItem])
        }
        items.append(contentsOf: videoInfos)
        return items
    }

    private func expandDefault() {
        let sections = rootItems.filter { !$0.isLeaf }

        if sections.count <= 1 {
            for item in sections {
                outlineView.expandItem(item)
            }
            return
        }

        guard currentItem > 0, currentItem < leafItems.count else {
            return
        }

        var offset = 0
        for section in sections {
            let count = section.children.filter(\.isLeaf).count
            if currentItem >= offset, currentItem < offset + count {
                outlineView.expandItem(section)
                return
            }
            offset += count
        }

        outlineView.expandItem(sections.first!)
    }

    var leafItems: [VideoTreeNode] {
        videoInfos.flatMap { $0.children.filter(\.isLeaf) }
    }

    private func displayString(for node: VideoTreeNode) -> String {
        var s = ""
        switch node.site {
        case .bilibili:
            if node.isCollection {
                s = node.title
            } else {
                s = "\(node.index)  \(node.title)"
            }
        case .bangumi:
            s = node.title
            if !node.longTitle.isEmpty {
                s += "  \(node.longTitle)"
            }
        case .douyu, .douyuVod, .huya, .biliLive, .cc163:
            s = (node.isLiving ? "🔥" : "") + node.title
        default:
            break
        }
        return s
    }

    // MARK: 回放缓存右键菜单

    enum ReplayCacheKind {
        case part
        case session
    }

    private var replayMenuInstalled = false
    private var clickedReplayNode: VideoTreeNode?

    /// 回放树的右键菜单：缓存单个分P / 缓存整场。
    func setupReplayCacheMenu() {
        guard !replayMenuInstalled else { return }
        replayMenuInstalled = true
        let menu = NSMenu()
        for kind in [ReplayCacheKind.part, .session] {
            let title = kind == .part
                ? NSLocalizedString("ReplayCache.CachePart", comment: "Cache This Part…")
                : NSLocalizedString("ReplayCache.CacheSessionPlain", comment: "Cache Whole Session…")
            let item = NSMenuItem(title: title,
                                  action: #selector(cacheReplay(_:)),
                                  keyEquivalent: "")
            item.representedObject = kind
            item.target = self
            menu.addItem(item)
        }
        menu.delegate = self
        outlineView.menu = menu
    }

    private func updateReplayCacheMenu(_ menu: NSMenu) {
        updateReplayCacheMenu(menu, row: clickedReplayRow())
    }

    private func updateReplayCacheMenu(_ menu: NSMenu, row: Int) {
        clickedReplayNode = row >= 0 ? outlineView.item(atRow: row) as? VideoTreeNode : nil
        let node = clickedReplayNode
        for item in menu.items {
            guard let kind = item.representedObject as? ReplayCacheKind else { continue }
            // 默认可见：行解析失败时菜单也不能是空的；点下去时会按当时所在行重新解析
            item.isHidden = false
            guard let node else { continue }
            switch kind {
            case .part:
                item.isHidden = !(node.isLeaf && node.site == .douyuVod)
            case .session:
                item.isHidden = !(!node.isLeaf && node.children.contains(where: { $0.site == .douyuVod }))
                item.title = String(format: NSLocalizedString("ReplayCache.CacheSession", comment: "cache session (%d parts)"),
                                    node.children.count)
            }
        }
    }

    /// 右键菜单弹出的行：优先鼠标所在行（outline 的 clickedRow 在这里可能拿不到），
    /// 其次 clickedRow / 选中行。
    private func clickedReplayRow() -> Int {
        let mouseLocation = outlineView.window?.mouseLocationOutsideOfEventStream
            ?? NSEvent.mouseLocation
        let mouseRow = outlineView.row(at: outlineView.convert(mouseLocation, from: nil))
        if mouseRow >= 0 { return mouseRow }
        let clicked = outlineView.clickedRow
        if clicked >= 0 { return clicked }
        return outlineView.selectedRow
    }

    @objc func cacheReplay(_ sender: NSMenuItem) {
        // 菜单还开着，鼠标就在那一行上：按当下位置重新解析，避免菜单打开时的解析过期
        if clickedReplayNode == nil {
            clickedReplayNode = outlineView.item(atRow: clickedReplayRow()) as? VideoTreeNode
        }
        guard let node = clickedReplayNode,
              node.site == .douyuVod,
              let main = parent as? MainViewController else {
            Log("Replay cache: no douyuVod node for the clicked row.")
            return
        }
        let section = outlineView.parent(forItem: node) as? VideoTreeNode
        let sessionTitle = section?.title ?? node.title

        if node.isLeaf {
            main.showReplayCache(pending: .init(
                sessionTitle: sessionTitle,
                parts: [ReplayCacheView.PendingPart(
                    hashId: node.id,
                    partNum: node.index,
                    durationSecs: node.duration,
                    title: node.title)]))
        } else {
            main.showReplayCache(pending: .init(
                sessionTitle: node.title,
                parts: node.children.filter { $0.site == .douyuVod }.map {
                    ReplayCacheView.PendingPart(hashId: $0.id,
                                                partNum: $0.index,
                                                durationSecs: $0.duration,
                                                title: $0.title)
                }))
        }
    }
}

extension SelectVideoViewController: NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == outlineView.menu {
            updateReplayCacheMenu(menu)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return rootItems.count
        } else if let node = item as? VideoTreeNode, !node.isLeaf {
            return node.children.filter(\.isLeaf).count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return rootItems[index]
        } else if let node = item as? VideoTreeNode, !node.isLeaf {
            return node.children.filter(\.isLeaf)[index]
        }
        return VideoTreeNode(title: "", id: "")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? VideoTreeNode else { return false }
        return !node.isLeaf
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? VideoTreeNode else { return nil }

        if node.isLeaf {
            let identifier = NSUserInterfaceItemIdentifier("SelectVideoCellView")
            guard let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView else {
                return nil
            }
            let s = displayString(for: node)
            cell.textField?.stringValue = s
            cell.textField?.toolTip = s
            return cell
        } else {
            let identifier = NSUserInterfaceItemIdentifier("SelectVideoGroupHeader")
            guard let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView else {
                return nil
            }
            cell.textField?.stringValue = node.title
            cell.textField?.toolTip = node.title
            return cell
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? VideoTreeNode else { return 24 }
        return node.isLeaf ? 34 : 32
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? VideoTreeNode, !node.isLeaf else { return true }
        if outlineView.isItemExpanded(item) {
            outlineView.animator().collapseItem(item)
        } else {
            outlineView.animator().expandItem(item)
        }
        return false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0,
              let item = outlineView.item(atRow: row) as? VideoTreeNode,
              item.isLeaf else { return }

        guard let main = self.parent as? MainViewController else { return }

        main.selectTabItem(.search)

        var u = ""
        switch item.site {
        case .bilibili:
            if item.isCollection {
                u = "https://www.bilibili.com/video/\(item.bvid)"
            } else {
                u = "https://www.bilibili.com/video/\(item.bvid)?p=\(item.index)"
            }
        case .douyu, .douyuVod, .huya, .biliLive:
            u = item.url
        case .bangumi:
            u = "https://www.bilibili.com/bangumi/play/ep\(item.id)"
        case .cc163:
            u = item.url
            main.searchField.stringValue = u
            main.searchField.becomeFirstResponder()
            main.startSearchingUrl(u, directly: false)
            outlineView.deselectRow(row)
            return
        default:
            break
        }
        main.searchField.stringValue = u
        main.searchField.becomeFirstResponder()
        main.startSearchingUrl(u, directly: true)
        outlineView.deselectRow(row)
    }
}
