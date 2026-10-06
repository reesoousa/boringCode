//
//  ClipboardItemCard.swift
//  boringCode
//
//  Um cartão do histórico: no topo, o ícone do app de onde veio, há quanto tempo
//  e o tipo; embaixo, a prévia (texto, link, imagem ou arquivo). Mesmo visual
//  dos cartões do monitor e da Shelf: cinza 0.06, cantos 12.
//

import AppKit
import SwiftUI

struct ClipboardItemCard: View {
    let item: ClipboardItem
    let appeared: Bool
    /// Posição na cascata de entrada.
    let order: Int
    let copied: Bool
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 124, height: 100)

    private var entrance: Animation {
        reduceMotion ? .smooth(duration: 0.2)
            : .spring(response: 0.6, dampingFraction: 0.82).delay(Double(order) * 0.05)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                header
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(8)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.11 : 0.06))
            )
            .overlay { copiedBadge }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(ClipboardCardButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: hovering)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
        .blur(radius: appeared || reduceMotion ? 0 : 6)
        .offset(y: appeared || reduceMotion ? 0 : 8)
        .animation(entrance, value: appeared)
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityDescription))
        .accessibilityHint(Text("Pastes into the app you were using"))
    }

    // MARK: - Topo

    private var header: some View {
        HStack(spacing: 5) {
            ClipboardSourceIcon(bundleID: item.sourceBundleID, fallbackSymbol: kindSymbol)
                .frame(width: 14, height: 14)
            // TaskTimeline: um TimelineView por cartão acordava o app a cada quadro da tela.
            TaskTimeline(interval: 30) { now in
                Text(verbatim: ClipboardTime.short(item.date, now: now))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.gray)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 2)
            Image(systemName: kindSymbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.gray.opacity(0.8))
        }
        .frame(height: 14)
    }

    private var kindSymbol: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }

    // MARK: - Prévia

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .text:
            Text(verbatim: Self.previewText(item.text ?? ""))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(5)
                .multilineTextAlignment(.leading)
        case .link:
            linkPreview
        case .image:
            imagePreview
        case .file:
            filePreview
        }
    }

    private var linkPreview: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: item.linkURL?.host() ?? item.text ?? "")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(verbatim: Self.displayURL(item.text ?? ""))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.gray)
                .lineLimit(3)
        }
    }

    /// A imagem preenche o espaço da prévia sem mudar o tamanho dela (senão empurrava o
    /// topo do cartão para fora).
    private var imagePreview: some View {
        Color.white.opacity(0.04)
            .overlay {
                ClipboardThumbnail(url: item.imageFile.map(ClipboardStorage.imageURL(named:)), fallbackSymbol: "photo", fill: true, isImage: true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let size = item.imagePixelSize {
                    Text(verbatim: "\(Int(size.width))×\(Int(size.height))")
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(4)
                }
            }
    }

    private var filePreview: some View {
        let urls = item.fileURLs
        return VStack(spacing: 4) {
            ClipboardThumbnail(url: urls.first, fallbackSymbol: "doc", fill: false, isImage: false)
                .frame(width: 38, height: 38)
            Text(verbatim: urls.count > 1
                 ? String(localized: "\(urls.count) files")
                 : (urls.first?.lastPathComponent ?? ""))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "Copiado" por cima do cartão, quando o item só foi copiado (sem colar).
    @ViewBuilder
    private var copiedBadge: some View {
        if copied {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.6))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5)
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Copied")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
    }

    // MARK: - Menu

    @ViewBuilder
    private var menu: some View {
        Button("Paste", action: onSelect)
        Button("Copy", action: onCopy)
        if let url = item.linkURL {
            Button("Open Link") { NSWorkspace.shared.open(url) }
        }
        if item.kind == .file, !item.fileURLs.isEmpty {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.fileURLs) }
        }
        Divider()
        Button("Delete", role: .destructive, action: onDelete)
    }

    private var accessibilityDescription: String {
        let content: String
        switch item.kind {
        case .text, .link: content = String((item.text ?? "").prefix(200))
        case .image: content = String(localized: "Image")
        case .file: content = item.fileURLs.map(\.lastPathComponent).joined(separator: ", ")
        }
        let source = item.sourceName.map { ", \($0)" } ?? ""
        return content + source
    }

    // MARK: - Texto

    /// Sem espaços e linhas em branco no começo, e no máximo umas linhas (é só uma prévia).
    static func previewText(_ text: String) -> String {
        let lines = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(6)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return String(lines.joined(separator: "\n").prefix(400))
    }

    /// Endereço sem "https://" e "www.", que não dizem nada.
    static func displayURL(_ text: String) -> String {
        var url = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where url.lowercased().hasPrefix(prefix) {
            url.removeFirst(prefix.count)
        }
        if url.lowercased().hasPrefix("www.") { url.removeFirst(4) }
        return url
    }
}

/// Aperto: o cartão afunda um pouco; com o ponteiro em cima, cresce de leve.
private struct ClipboardCardButtonStyle: ButtonStyle {
    let hovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.96 : hovering ? 1.03 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: hovering)
    }
}

/// "agora", "5 min", "2 h", "3 d" — curto, como no cabeçalho dos cartões.
enum ClipboardTime {
    static func short(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return String(localized: "now")
        case ..<3600: return String(localized: "\(Int(seconds / 60)) min")
        case ..<86400: return String(localized: "\(Int(seconds / 3600)) h")
        default: return String(localized: "\(Int(seconds / 86400)) d")
        }
    }
}

/// Ícone do app de onde o item veio (cacheado: o mesmo app aparece em vários cartões).
struct ClipboardSourceIcon: View {
    let bundleID: String?
    let fallbackSymbol: String

    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let image = icon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.gray)
        }
    }

    private var icon: NSImage? {
        guard let bundleID else { return nil }
        if let cached = Self.cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        Self.cache[bundleID] = image
        return image
    }
}

/// Miniatura que aparece suave quando chega. Imagem copiada: reduzida direto do
/// arquivo (o Quick Look no modo ícone devolvia o ícone do app padrão do PNG, como
/// "</>" de um editor); arquivo: Quick Look, o mesmo da Shelf.
struct ClipboardThumbnail: View {
    let url: URL?
    let fallbackSymbol: String
    /// Imagem preenche o cartão (cortando as sobras); arquivo cabe inteiro.
    let fill: Bool
    let isImage: Bool

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
                    .transition(.opacity)
            } else if !fill, let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .scaledToFit()
            } else {
                Color.white.opacity(0.04)
                    .overlay {
                        Image(systemName: fallbackSymbol)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.gray)
                    }
            }
        }
        .animation(.smooth(duration: 0.25), value: image != nil)
        .task(id: url) {
            guard let url else { return }
            if isImage {
                image = await Task.detached(priority: .userInitiated) {
                    ClipboardStorage.thumbnail(at: url, maxPixelSize: 360)
                }.value
            } else {
                image = await ThumbnailService.shared.thumbnail(for: url, size: CGSize(width: 240, height: 200))
            }
        }
    }
}
