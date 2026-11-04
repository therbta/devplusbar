import AppKit
import SwiftUI

/// Yeni bir PR / issue geldiginde menu cubugu ikonunun altindan kayarak inen kucuk kutu.
///
/// macOS bildirimi ekranin sag ustunde, Bildirim Merkezi'nin elinde; bu ise dogrudan
/// ikona bagli, panelle ayni oklu cizimle. Birkac saniye sonra kendiliginden kalkar,
/// fare ustundeyken beklemede kalir. Tiklamak ogeyi acar (birden fazlaysa paneli).
@MainActor
final class BarToast {

    /// Ekranda kalma suresi; fare ustundeyken sayac durur.
    static let duration: Duration = .seconds(6)

    var onOpen: ((String) -> Void)?
    var onOpenSummary: (() -> Void)?

    private let statusItem: NSStatusItem
    private let style: ArrowPanelStyle
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    init(statusItem: NSStatusItem, style: ArrowPanelStyle) {
        self.statusItem = statusItem
        self.style = style
    }

    func show(_ items: [Item]) {
        guard !items.isEmpty else { return }
        present { position, hover in
            AnyView(BarToastView(items: items, style: self.style, position: position,
                onClick: { [weak self] in
                    guard let self else { return }
                    self.close()
                    if items.count == 1 { self.onOpen?(items[0].url) } else { self.onOpenSummary?() }
                },
                onHover: hover))
        }
    }

    /// Deployment changes. A failure stays until it is clicked or hovered away.
    func show(deploys alerts: [DeployAlert]) {
        let shown = alerts.filter(\.toast)
        guard !shown.isEmpty else { return }
        let sticky = shown.contains { $0.transition.to == .failed || $0.crash }
        present(sticky: sticky) { position, hover in
            AnyView(DeployToastView(alerts: shown, style: self.style, position: position,
                onClick: { [weak self] in
                    guard let self else { return }
                    self.close()
                    let d = shown[0].transition.deployment
                    if shown.count == 1, let address = (d.state == .failed ? d.dashboardURL : d.url ?? d.dashboardURL) {
                        self.onOpen?(address.absoluteString)
                    } else {
                        self.onOpenDeploys?()
                    }
                },
                onHover: hover))
        }
    }

    var onOpenDeploys: (() -> Void)?
    /// A notice without a URL opens the panel on this side.
    var onOpenMode: ((PanelMode) -> Void)?

    /// Notices: limits, unpushed work, workflows, comments. Up to three at once.
    func show(notices: [BarNotice]) {
        guard !notices.isEmpty else { return }
        present(sticky: notices.contains(where: \.sticky)) { position, hover in
            AnyView(NoticeToastView(notices: notices, style: self.style, position: position,
                onClick: { [weak self] in
                    guard let self else { return }
                    self.close()
                    let first = notices[0]
                    if notices.count == 1, let url = first.url { self.onOpen?(url) }
                    else if let mode = first.mode { self.onOpenMode?(mode) }
                    else { self.onOpenSummary?() }
                },
                onHover: hover))
        }
    }

    private func present(sticky: Bool = false,
                         _ make: (ArrowPosition, @escaping (Bool) -> Void) -> AnyView) {
        guard let button = statusItem.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        close()

        let position = ArrowPosition()
        let content = make(position) { [weak self] inside in
            if inside { self?.dismissal?.cancel() } else if !sticky { self?.scheduleDismissal() }
        }
        let hosting = NSHostingView(rootView: content)

        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = hosting

        // StatusPanel.layout ile ayni hesap: ikonun altinda ortali, ekrandan tasmadan.
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = hosting.fittingSize
        let visible = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - 8 - size.width)
        position.x = anchor.midX - x
        panel.setFrame(NSRect(x: x, y: anchor.minY - style.gap - size.height,
                              width: size.width, height: size.height), display: true)
        // Odak calmadan one gelir: yazdigin yerden klavye kaymaz.
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak panel] in panel?.invalidateShadow() }

        self.panel = panel
        if sticky {
            dismissal?.cancel()
            dismissal = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.close()
            }
        } else {
            scheduleDismissal()
        }
    }

    func close() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// `--demo-toast` icin uydurma ogeler; gercek kimsenin adi gecmez.
    static func demoItems(_ count: Int) -> [Item] {
        (1...max(1, count)).map { n in
            Item(kind: n.isMultiple(of: 2) ? .issue : .pullRequest, repository: "therbta/devplusbar",
                 number: 40 + n, title: "Add keyboard navigation to the menu (\(n))",
                 url: "https://github.com/therbta/devplusbar", createdAt: Date(), isDraft: false,
                 authorLogin: "octocat", authorIsBot: false)
        }
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }
}

/// Kutunun icerigi. Pencere sabit; icerik yukaridan kayarak girer, pencerenin ust kenari
/// onu kirptigi icin ikonun altindan cikiyormus gibi gorunur.
private struct BarToastView: View {
    let items: [Item]
    let style: ArrowPanelStyle
    @ObservedObject var position: ArrowPosition
    let onClick: () -> Void
    let onHover: (Bool) -> Void
    @State private var shown = false

    var body: some View {
        ArrowPanelContainer(position: position, style: style, content: AnyView(card))
            .offset(y: shown ? 0 : -24)
            .opacity(shown ? 1 : 0)
            .clipped()
            .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { shown = true } }
            .onHover(perform: onHover)
            .onTapGesture(perform: onClick)
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 10) {
            if items.count == 1 {
                AuthorAvatar(login: items[0].authorLogin, isBot: items[0].authorIsBot)
                    .frame(width: 28, height: 28)
            } else {
                Circle().fill(Ink.accent).frame(width: 8, height: 8).padding(.top, 5)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(heading).font(Ink.meta).foregroundStyle(Ink.accent)
                if items.count == 1 {
                    Text(items[0].title).font(Ink.body).foregroundStyle(Ink.primary).lineLimit(2)
                    Text("@\(items[0].authorLogin)").font(Ink.meta).foregroundStyle(Ink.secondary)
                } else {
                    ForEach(items.prefix(3)) { item in
                        Text("\(item.repositoryName) #\(item.number) · \(item.title)")
                            .font(Ink.body).foregroundStyle(Ink.primary).lineLimit(1)
                    }
                    if items.count > 3 {
                        Text("and \(items.count - 3) more").font(Ink.meta).foregroundStyle(Ink.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 320)
        .contentShape(Rectangle())
    }

    private var heading: String {
        guard items.count == 1 else { return "\(items.count) new items" }
        let item = items[0]
        let kind = item.kind == .pullRequest ? "New pull request" : "New issue"
        return "\(kind) · \(item.repositoryName) #\(item.number)"
    }
}

/// The toast for deployment changes.
private struct DeployToastView: View {
    let alerts: [DeployAlert]
    let style: ArrowPanelStyle
    @ObservedObject var position: ArrowPosition
    let onClick: () -> Void
    let onHover: (Bool) -> Void
    @State private var shown = false

    var body: some View {
        ArrowPanelContainer(position: position, style: style, content: AnyView(card))
            .offset(y: shown ? 0 : -24)
            .opacity(shown ? 1 : 0)
            .clipped()
            .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { shown = true } }
            .onHover(perform: onHover)
            .onTapGesture(perform: onClick)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(alerts.prefix(3), id: \.transition.deployment.id) { alert in
                let d = alert.transition.deployment
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        Circle().fill(DeployText.tint(d).opacity(0.18))
                        Image(systemName: DeployText.symbol(d))
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(DeployText.tint(d))
                    }
                    .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(d.provider.title) · \(d.target.title)").font(Ink.meta).foregroundStyle(DeployText.tint(d))
                        Text(DeployText.headline(alert.transition)).font(Ink.body).foregroundStyle(Ink.primary).lineLimit(1)
                        let detail = DeployText.detail(d)
                        if !detail.isEmpty {
                            Text(detail).font(Ink.meta).foregroundStyle(Ink.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if alerts.count > 3 {
                Text("and \(alerts.count - 3) more").font(Ink.meta).foregroundStyle(Ink.secondary)
            }
        }
        .padding(14)
        .frame(width: 320)
        .contentShape(Rectangle())
    }
}

/// The toast for notices.
private struct NoticeToastView: View {
    let notices: [BarNotice]
    let style: ArrowPanelStyle
    @ObservedObject var position: ArrowPosition
    let onClick: () -> Void
    let onHover: (Bool) -> Void
    @State private var shown = false

    var body: some View {
        ArrowPanelContainer(position: position, style: style, content: AnyView(card))
            .offset(y: shown ? 0 : -24)
            .opacity(shown ? 1 : 0)
            .clipped()
            .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { shown = true } }
            .onHover(perform: onHover)
            .onTapGesture(perform: onClick)
    }

    static func tint(_ tone: BarNotice.Tone) -> Color {
        switch tone {
        case .warning: Ink.warning
        case .failure: Ink.red
        case .info: Ink.accent
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(notices.prefix(3)) { notice in
                let tint = Self.tint(notice.tone)
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        Circle().fill(tint.opacity(0.18))
                        Image(systemName: notice.symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                    }
                    .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.heading).font(Ink.meta).foregroundStyle(tint).lineLimit(1)
                        Text(notice.title).font(Ink.body).foregroundStyle(Ink.primary).lineLimit(2)
                        if let detail = notice.detail {
                            Text(detail).font(Ink.meta).foregroundStyle(Ink.secondary).lineLimit(3)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if notices.count > 3 {
                Text("and \(notices.count - 3) more").font(Ink.meta).foregroundStyle(Ink.secondary)
            }
        }
        .padding(14)
        .frame(width: 320)
        .contentShape(Rectangle())
    }
}
