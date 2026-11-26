/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI
import AppKit
import Defaults

/// Clipboard as a card grid, each card draggable out to other apps, tap to copy,
/// hover to delete. Used both as the dedicated `.notchTab` view and, at a smaller
/// `minCardWidth`, as the clipboard panel in `.separateTab` split mode. The adaptive
/// grid fills whatever width it is given (more columns in the full notch tab, fewer
/// in the narrow split panel).
struct NotchClipboardView: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject var clipboardManager = ClipboardManager.shared
    @State private var hoveredItemId: UUID?
    @State private var justCopiedId: UUID?
    @State private var suppressionToken = UUID()
    @State private var isSuppressing = false
    @State private var showClearHistoryAlert = false
    @State private var autoCloseToken = UUID()
    /// 标题行实测高度；列表靠它让开位置（空状态不用，它走 offset 对齐）。
    @State private var headerHeight: CGFloat = 44
    /// 分类筛选。写进 Defaults，岛收起再打开还停在原来的分类上。
    @Default(.clipboardCategory) private var category


    /// Minimum card width; drives how many columns the adaptive grid shows.
    var minCardWidth: CGFloat = 200
    /// Force an exact column count (used by the narrow `.separateTab` panel, where an
    /// adaptive minimum would collapse to a single column). nil = adaptive by width.
    var fixedColumns: Int? = nil

    /// 当前分类下的条目；`.all` 不筛选。
    private var filteredHistory: [ClipboardItem] {
        guard category != .all else { return clipboardManager.clipboardHistory }
        return clipboardManager.clipboardHistory.filter { category.matches($0.type) }
    }
    private var columns: [GridItem] {
        if let n = fixedColumns {
            return Array(repeating: GridItem(.flexible(), spacing: 8), count: max(1, n))
        }
        return [GridItem(.adaptive(minimum: minCardWidth, maximum: .infinity), spacing: 8)]
    }

    /// 空状态靠上下等分居中（不额外加 padding）：实测加 36pt 反而会把中心
    /// 往下顶 18pt，跟暂存架那条线错开。

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if clipboardManager.clipboardHistory.isEmpty {
                    emptyState
                } else if filteredHistory.isEmpty {
                    filteredEmptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(filteredHistory) { item in
                                ClipboardGridCard(
                                    item: item,
                                    isHovered: hoveredItemId == item.id,
                                    justCopied: justCopiedId == item.id,
                                    onDelete: { clipboardManager.deleteItem(item) }
                                )
                                .contentShape(Rectangle())
                                .clipboardDraggable(item)
                                .onHover { hovering in
                                    // Only clear on exit if the id still refers to this card:
                                    // entering the next card can fire `true` before this card's
                                    // `false`, and an unconditional nil would wipe that entry.
                                    if hovering { hoveredItemId = item.id }
                                    else if hoveredItemId == item.id { hoveredItemId = nil }
                                }
                                .onTapGesture { copy(item) }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(item.type.displayName): \(item.preview)")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { copy(item) }
                                .accessibilityAction(named: Text("Delete")) { clipboardManager.deleteItem(item) }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                    // 列表得让开标题行，否则卡片会滑到 chip 下面。
                    .padding(.top, headerHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
        }
        // alignment: .top 不能省：默认是居中，而两种状态的内容高度不一样（有 chip / 没 chip），
        // 整体会被上下居中，未尾就是标题跟着上下飘几 pt。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover { updateSuppression(for: $0) }
        .onDisappear {
            updateSuppression(for: false)
            // Release the alert-driven suppression too: if the view is torn down while
            // the clear-history alert is open, onChange never fires false and it leaks.
            vm.setAutoCloseSuppression(false, token: autoCloseToken)
        }
        // 系统 .alert 会在整个面板上铺遮罩 —— 面板比岛大，会露出灰色矩形。
        // 改成岛内自绘确认卡，遮罩只落在卡片上。
        .overlay {
            if showClearHistoryAlert {
                clearHistoryConfirmCard
            }
        }
        .onChange(of: showClearHistoryAlert) { _, isShowing in
            vm.setAutoCloseSuppression(isShowing, token: autoCloseToken)
        }
        .onAppear {
            if Defaults[.enableClipboardManager], !clipboardManager.isMonitoring {
                clipboardManager.startMonitoring()
            }
        }
    }

    private var clearHistoryConfirmCard: some View {
        VStack(spacing: 10) {
            Text("Clear Clipboard History?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text("This removes every saved clipboard item from the notch tab.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    showClearHistoryAlert = false
                } label: {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(.white.opacity(0.12)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    clipboardManager.clearHistory()
                    showClearHistoryAlert = false
                } label: {
                    Text("Clear History")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: 320)
        .background {
            // 不透明：半透明时后面的空状态/卡片会透上来，看着像字叠字。
            // 比岛底黑略亮一点，靠颜色差 + 描边把卡片从背景里拎出来。
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(white: 0.11))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
        .padding(12)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    /// 标题、分类 chip、清空按钮共处一行。
    ///
    /// 以前 chip 另起一行，内容区被压低 ~36pt，空状态就跟暂存架页对不齐了
    /// （展开态整块只有 200pt）。并到一行以后内容区起点与暂存架一致。
    private var header: some View {
        HStack(spacing: 12) {
            Text("Clipboard")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize()

            if !clipboardManager.clipboardHistory.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ClipboardCategory.allCases) { chip in
                            categoryChip(chip)
                        }
                    }
                }
                .frame(height: 24)
            }

            Spacer(minLength: 8)

            if !clipboardManager.clipboardHistory.isEmpty {
                Button(action: { showClearHistoryAlert = true }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                        .frame(width: 16, height: 16)
                        .padding(5)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel(Text("Clear History"))
            }
        }
        // 行高钉死：有 chip 时行高 26，没 chip 时只剩标题（~19），
        // 不钉的话标题会在空/非空两种状态之间上下飘 5pt。
        .frame(height: 26)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }


    private func categoryChip(_ chip: ClipboardCategory) -> some View {
        let isSelected = category == chip
        let count = categoryCount(chip)

        return Button {
            withAnimation(Motion.respected(.easeInOut(duration: 0.15))) {
                category = chip
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: chip.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(chip.title)
                    .font(.system(size: 11, weight: .medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(0.65)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.1)))
            .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(chip.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func categoryCount(_ chip: ClipboardCategory) -> Int {
        guard chip != .all else { return clipboardManager.clipboardHistory.count }
        return clipboardManager.clipboardHistory.reduce(into: 0) { total, item in
            if chip.matches(item.type) { total += 1 }
        }
    }

    /// 该分类下没有内容（历史里其实是有的）。
    ///
    /// 不给 minHeight：展开态高度固定 200pt，头部 + 分类条已占掉约 76pt，
    /// 再要求 140pt 会把内容顶出窗口底部（上一个版本的「全部」按钮就被裁掉一半）。
    /// 回到「全部」不需要额外按钮 —— 上面那排 chip 就在旁边。
    private var filteredEmptyState: some View {
        emptyStateContent(message: "No items in this category")
    }

    private var emptyState: some View {
        emptyStateContent(message: "No copies yet")
    }

    /// 空状态的唯一实现：只一行字，不画图标。
    ///
    /// 位置：标题行占掉顶部一块，肉眼要求的「居中」是居中在标题行下方剩下的空间里
    /// （实测面板 0..210，标题内容到 85，目标中心 ~147）。
    /// SwiftUI 给这个视图的高度比可见面板大，直接 `maxHeight: .infinity` 居中的话
    /// 会落在 121 左右、贴着标题行，所以用 offset 补下去。
    private static let emptyStateVerticalOffset: CGFloat = 23

    private func emptyStateContent(message: LocalizedStringKey) -> some View {
        Text(message)
            .foregroundStyle(.gray)
            .font(.system(.title3, design: .rounded))
            .fontWeight(.medium)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: Self.emptyStateVerticalOffset)
    }

    private func copy(_ item: ClipboardItem) {
        clipboardManager.copyToClipboard(item)
        withAnimation { justCopiedId = item.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if justCopiedId == item.id {
                withAnimation { justCopiedId = nil }
            }
        }
    }

    private func updateSuppression(for hovering: Bool) {
        guard hovering != isSuppressing else { return }
        isSuppressing = hovering
        vm.setScrollGestureSuppression(hovering, token: suppressionToken)
    }
}

/// One clipboard entry as a compact card: thumbnail/type icon, preview, meta,
/// and a hover-revealed delete button in the top-trailing corner.
struct ClipboardGridCard: View {
    let item: ClipboardItem
    let isHovered: Bool
    let justCopied: Bool
    let onDelete: () -> Void

    // Decode the image once per item instead of on every render. `body` re-runs for hover
    // and copy-feedback changes, and decoding the on-disk PNG on the main thread each time
    // is wasteful; `.task(id:)` loads it once and refreshes only when the item changes.
    @State private var cachedImage: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(item.type.displayName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer(minLength: 0)
                    Text(timeAgoString(from: item.timestamp))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(isHovered ? 0.12 : 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, .black.opacity(0.5))
                }
                .buttonStyle(PlainButtonStyle())
                .help("Delete this item")
                .accessibilityLabel(Text("Delete this item"))
                .padding(4)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Motion.respected(.easeInOut(duration: 0.12)), value: isHovered)
        .task(id: item.id) {
            cachedImage = item.type == .image
                ? item.getImageData().flatMap(NSImage.init(data:))
                : nil
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if item.type == .image, let nsImage = cachedImage {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                .overlay {
                    // Copy confirmation for image cards (the icon cards swap to a checkmark;
                    // image cards keep their thumbnail, so badge the checkmark on top).
                    if justCopied {
                        RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.5))
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.green)
                    }
                }
        } else {
            Image(systemName: justCopied ? "checkmark.circle.fill" : item.type.icon)
                .font(.system(size: 16))
                .foregroundColor(justCopied ? .green : .blue)
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func timeAgoString(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return String(localized: "Just now") }
        if interval < 3600 { return String(localized: "\(Int(interval/60))m") }
        return String(localized: "\(Int(interval/3600))h")
    }
}
