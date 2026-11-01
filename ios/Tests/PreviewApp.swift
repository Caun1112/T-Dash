// Simulator-only native UIKit layout inspection. Not linked into the DEB.
import UIKit

private final class PreviewMap: UIView {
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        UIColor(red: 0.10, green: 0.14, blue: 0.16, alpha: 1).setFill(); ctx.fill(rect)
        ctx.setLineWidth(20); ctx.setStrokeColor(UIColor(white: 0.28, alpha: 0.7).cgColor)
        for i in -3...12 {
            ctx.move(to: CGPoint(x: CGFloat(i) * 100, y: 0))
            ctx.addLine(to: CGPoint(x: CGFloat(i) * 100 + 200, y: rect.height)); ctx.strokePath()
        }
        ctx.setLineWidth(15)
        for i in 1...8 {
            ctx.move(to: CGPoint(x: 0, y: CGFloat(i) * 100))
            ctx.addLine(to: CGPoint(x: rect.width, y: CGFloat(i) * 100 - 100)); ctx.strokePath()
        }
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.width * 0.46, y: rect.height + 20))
        path.addLine(to: CGPoint(x: rect.width * 0.46, y: rect.height * 0.56))
        path.addLine(to: CGPoint(x: rect.width * 0.65, y: rect.height * 0.45))
        path.addLine(to: CGPoint(x: rect.width * 0.65, y: -20))
        UIColor(red: 0.12, green: 0.42, blue: 1, alpha: 1).setStroke(); path.lineWidth = 13; path.stroke()
        UIColor(red: 0.45, green: 0.78, blue: 1, alpha: 1).setStroke(); path.lineWidth = 4; path.stroke()
        let text = "↱  800 米后右转"
        let banner = CGRect(x: 20, y: 26, width: min(300, rect.width - 40), height: 72)
        UIColor(red: 0.07, green: 0.21, blue: 0.19, alpha: 0.96).setFill()
        UIBezierPath(roundedRect: banner, cornerRadius: 16).fill()
        text.draw(at: CGPoint(x: banner.minX + 16, y: banner.minY + 21), withAttributes: [.font: UIFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: UIColor.white])
        "布局预览 · 模拟车辆数据 / 非高德实机截图".draw(at: CGPoint(x: 20, y: rect.height - 30), withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.white.withAlphaComponent(0.8)])
    }
}

@main enum PreviewCLI {
    static func main() {
        precondition(CommandLine.arguments.count == 2)
        PreviewRenderer().renderPreviews(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
final class PreviewRenderer {
    fileprivate func renderPreviews(to folder: URL) {
        let prefs = UserDefaults(suiteName: "com.caun.tdash.amap")!
        prefs.removePersistentDomain(forName: "com.caun.tdash.amap")
        let client = TDTeslaClient(); client.loadPreviewFixture()
        let dashboard = TDDashboardController(client: client)
        _ = dashboard.view
        func render(_ name: String, _ size: CGSize, _ controller: TDDashboardController) {
            let container = UIView(frame: CGRect(origin: .zero, size: size))
            let backdrop = PreviewMap(frame: container.bounds); container.addSubview(backdrop)
            controller.view.frame = container.bounds; container.addSubview(controller.view)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded(); controller.refresh()
            precondition(container.bounds.insetBy(dx: 9, dy: 9).contains(controller.panel.frame), "Panel escapes viewport: \(name)")
            for subview in controller.panel.subviews where !subview.isHidden {
                precondition(controller.panel.bounds.contains(subview.frame), "Clipped element: \(name) / \(type(of: subview))")
            }
            let format = UIGraphicsImageRendererFormat(); format.scale = 2
            backdrop.setNeedsDisplay(); backdrop.layer.displayIfNeeded()
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                container.layer.render(in: context.cgContext)
            }
            try! image.pngData()!.write(to: folder.appendingPathComponent("\(name).png"))
            controller.view.removeFromSuperview()
        }
        render("landscape", CGSize(width: 844, height: 390), dashboard)
        render("portrait", CGSize(width: 390, height: 844), dashboard)
        render("landscape-small", CGSize(width: 667, height: 375), dashboard)
        render("portrait-small", CGSize(width: 320, height: 568), dashboard)
        // Labels and dividers only: no visible button or secondary dashboard content.
        precondition(dashboard.panel.subviews.count == 5)
        precondition(!dashboard.panel.subviews.contains { $0 is UIControl })
        precondition(dashboard.panel.gestureRecognizers?.contains { $0 is UILongPressGestureRecognizer } == true)
        client.disconnect()
        render("disconnected", CGSize(width: 844, height: 390), dashboard)
        let labels = dashboard.panel.subviews.compactMap { $0 as? UILabel }
        precondition(labels.allSatisfy { ($0.attributedText?.string ?? $0.text ?? "").contains("—") })
        try! Data("PASS: native UIKit landscape, portrait, repeated rotation, small-screen bounds, long-press access and disconnected readings\n".utf8)
            .write(to: folder.appendingPathComponent("preview-complete.txt"))
    }
}
