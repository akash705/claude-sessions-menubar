import SwiftUI
import AppKit
import ImageIO

struct SessionRow: View {
    let session: Session
    var pendingPermission: PendingPermission? = nil
    var onAllow: (() -> Void)? = nil
    /// Deny with an optional free-text reason surfaced back to Claude via
    /// `permissionDecisionReason`. nil = plain deny.
    var onDeny: ((String?) -> Void)? = nil
    /// Allow this call AND persist a rule so identical calls stop prompting.
    /// Only wired when a specific, safe rule can be derived for the tool.
    var onAlwaysAllow: (() -> Void)? = nil
    var onOpenHistory: (() -> Void)? = nil
    /// Resume an ended session in a new terminal (`claude --resume`). Wired
    /// only for sessions with no live process — live ones focus instead.
    var onResume: (() -> Void)? = nil
    /// Called when the user taps the permission card anywhere outside the
    /// Allow/Deny buttons — lets them hop to the terminal to inspect/answer
    /// in context rather than deciding blind from the menubar.
    var onFocusTerminal: (() -> Void)? = nil
    /// Called when the user dismisses an informational permission card.
    /// Only wired up when `onAllow`/`onDeny` are nil (i.e. "decide in app"
    /// is off and the terminal owns the decision).
    var onDismiss: (() -> Void)? = nil

    /// Reveals the optional deny-reason field once the user taps Deny.
    @State private var showingDenyField = false
    @State private var denyReason = ""

    /// Permission card is "interactive" when both Allow and Deny handlers
    /// are wired up. If either is missing we render the informational
    /// variant — no buttons, a dismiss X, and an "answer in terminal" hint.
    private var isInteractivePermission: Bool {
        onAllow != nil && onDeny != nil
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        if pendingPermission != nil {
            permissionCard
        } else {
            compactRow
        }
    }

    private var compactRow: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusDot(status: session.status)
                .frame(width: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    // When a user-set name is the title, keep the project
                    // folder visible as a smaller secondary tag.
                    if session.userName != nil {
                        Text(session.projectLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    Text("#\(session.id.prefix(6))")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if let pid = session.pid {
                        Text("pid \(pid)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if session.isAwaitingPermission {
                        PermissionBadge()
                    }
                    Spacer(minLength: 0)
                    Text(Self.relative.localizedString(for: session.lastActivity, relativeTo: Date()))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if session.isAwaitingPermission, let t = session.pendingTool {
                    Text("Awaiting permission: \(t.name)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else {
                    Text(session.lastMessagePreview.isEmpty ? "(no messages)" : session.lastMessagePreview)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let onResume {
                Button {
                    onResume()
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Resume this session in a new terminal (claude --resume)")
            }

            Button {
                onOpenHistory?()
            } label: {
                Image(systemName: "bubble.left")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Open chat history")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .pointerCursor()
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(session.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let pid = session.pid {
                    Text("pid \(pid)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Text(Self.relative.localizedString(for: session.lastActivity, relativeTo: Date()))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if let pending = pendingPermission {
                HStack(alignment: .center, spacing: 8) {
                    PermissionBadge()
                    Text(toolTitle(pending))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                detail(for: pending)
            }

            if isInteractivePermission {
                actionButtons
            } else {
                informationalFooter
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 1)
        )
        // Make the card tappable as a whole; the action Buttons above
        // capture their own taps, so only the surrounding area routes here.
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { onFocusTerminal?() }
        .pointerCursor()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - Permission card: action area

    @ViewBuilder
    private var actionButtons: some View {
        if showingDenyField {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Reason (optional)", text: $denyReason)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { commitDeny() }
                HStack(spacing: 8) {
                    Button("Cancel") {
                        showingDenyField = false
                        denyReason = ""
                    }
                    .buttonStyle(PillActionStyle(tint: .gray, prominent: false))
                    .pointerCursor()
                    .help("Go back without answering the request")
                    Button("Send Deny") { commitDeny() }
                        .buttonStyle(PillActionStyle(tint: .red, prominent: true))
                        .pointerCursor()
                        .help("Deny the call and send this reason back to Claude")
                }
            }
        } else {
            HStack(spacing: 8) {
                Button("Allow") { onAllow?() }
                    .buttonStyle(PillActionStyle(tint: .green, prominent: true))
                    .pointerCursor()
                    .help("Allow this tool call once")
                if let onAlwaysAllow {
                    Button("Always") { onAlwaysAllow() }
                        .buttonStyle(PillActionStyle(tint: .blue, prominent: false))
                        .pointerCursor()
                        .help(alwaysAllowHelp)
                }
                Button("Deny") { showingDenyField = true }
                    .buttonStyle(PillActionStyle(tint: .red, prominent: false))
                    .pointerCursor()
                    .help("Deny this call — you can add a reason for Claude")
            }
        }
    }

    private func commitDeny() {
        let trimmed = denyReason.trimmingCharacters(in: .whitespacesAndNewlines)
        onDeny?(trimmed.isEmpty ? nil : trimmed)
        showingDenyField = false
        denyReason = ""
    }

    private var alwaysAllowHelp: String {
        if let pending = pendingPermission, let rule = HookInstaller.allowRule(for: pending) {
            return "Always allow — adds rule: \(rule)"
        }
        return "Always allow this call"
    }

    private var informationalFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("Answer in terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                onDismiss?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Dismiss notice")
        }
    }

    // MARK: - Permission card: per-tool detail

    private func toolTitle(_ pending: PendingPermission) -> String {
        if let c = pending.mcpComponents {
            return c.tool.isEmpty ? pending.toolName : "\(c.server) › \(c.tool)"
        }
        return pending.toolName
    }

    @ViewBuilder
    private func detail(for pending: PendingPermission) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch pending.kind {
            case .bash:
                codeBlock(pending.command ?? pending.summary)
            case .edit:
                if let path = pending.filePath { pathLabel(path) }
                diffView(old: pending.oldString ?? "", new: pending.newString ?? "")
            case .multiEdit:
                if let path = pending.filePath { pathLabel(path) }
                let edits = pending.edits
                Text("\(edits.count) edit\(edits.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                // Don't let a silently-partial preview mislead the approval.
                let dropped = pending.rawEditCount - edits.count
                if dropped > 0 {
                    Text("⚠︎ \(dropped) edit\(dropped == 1 ? "" : "s") couldn't be previewed")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
                if let first = edits.first {
                    diffView(old: first.old, new: first.new)
                }
            case .write:
                if let path = pending.filePath { pathLabel(path) }
                if let content = pending.content { codeBlock(content) }
            case .webFetch:
                if let url = pending.url { detailLine(url, mono: true) }
                if let prompt = pending.prompt { detailLine(prompt, mono: false) }
            case .ask:
                detailLine(pending.question ?? pending.summary, mono: false)
            case .mcp, .generic:
                paramList(pending.toolInput)
            }

            let images = pending.imagePaths
            if !images.isEmpty { thumbnails(images) }
        }
    }

    private func detailLine(_ text: String, mono: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, design: mono ? .monospaced : .default))
            .foregroundStyle(.primary.opacity(0.85))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pathLabel(_ path: String) -> some View {
        Text(path)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Bounded, scrollable monospaced block. Content is hard-capped so a
    /// whole-file `content` or a long command can't balloon the card.
    private func codeBlock(_ text: String, tint: Color = .primary) -> some View {
        ScrollView(.vertical) {
            Text(Self.capped(text))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tint.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private func diffView(old: String, new: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !old.isEmpty { codeBlock(old, tint: .red) }
            if !new.isEmpty { codeBlock(new, tint: .green) }
        }
    }

    private func paramList(_ input: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(input.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top, spacing: 6) {
                    Text(key)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(Self.capped(String(describing: input[key] ?? ""), maxChars: 240))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private func thumbnails(_ paths: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(paths, id: \.self) { path in
                    if let img = Self.thumbnail(path: path) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 120, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                    }
                }
            }
        }
        .frame(maxHeight: 92)
    }

    private static func capped(_ s: String, maxChars: Int = 2000) -> String {
        if s.count <= maxChars { return s }
        return String(s.prefix(maxChars)) + "\n… (truncated)"
    }

    /// Decoded thumbnails keyed by "path@maxPixel". The permission card's body
    /// re-evaluates on every store change (blink timer ~2×/s) and every
    /// deny-reason keystroke; without this the ImageIO decode would re-run on
    /// the main thread each time and jank the UI. NSCache is thread-safe and
    /// self-evicting under memory pressure. Screenshots are immutable temp
    /// files, so caching by path can't go stale in practice.
    private static let thumbnailCache = NSCache<NSString, NSImage>()

    /// Downscaled thumbnail via ImageIO — avoids loading a full-resolution
    /// screenshot into memory just to show a 120pt preview. Cached per path.
    private static func thumbnail(path: String, maxPixel: CGFloat = 240) -> NSImage? {
        let key = "\(path)@\(maxPixel)" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbnailCache.setObject(image, forKey: key)
        return image
    }
}

struct PillActionStyle: ButtonStyle {
    let tint: Color
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(prominent ? tint.opacity(0.9) : tint.opacity(0.14))
            )
            .opacity(configuration.isPressed ? 0.75 : 1.0)
    }
}

struct PermissionBadge: View {
    var body: some View {
        Text("PERMISSION")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
            .foregroundStyle(Color.orange)
    }
}

struct StatusDot: View {
    let status: SessionStatus
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.5), radius: 2, x: 0, y: 0)
    }
    private var color: Color {
        switch status {
        case .running: return .green
        case .pending: return .orange
        case .idle:    return .gray
        case .done:    return .blue
        case .error:   return .red
        }
    }
}
