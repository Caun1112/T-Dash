// Design proposal only. Does not change the shipping iOS dashboard.
// Run: swift ios/design/render-round-preview.swift <absolute-output.png>
import AppKit

let W: CGFloat = 1536, H: CGFloat = 1280
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
let white = color(0.94,0.96,0.98), muted = color(0.57,0.63,0.68), mint = color(0.33,0.91,0.74), amber = color(1,0.61,0.22)
func box(_ rect: CGRect, _ fill: NSColor, radius: CGFloat = 0, stroke: NSColor? = nil, width: CGFloat = 1) {
    let p = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(p); ctx.setFillColor(fill.cgColor); ctx.fillPath()
    if let stroke = stroke { ctx.addPath(p); ctx.setStrokeColor(stroke.cgColor); ctx.setLineWidth(width); ctx.strokePath() }
}
func line(_ points: [CGPoint], _ c: NSColor, _ width: CGFloat) {
    guard let first = points.first else { return }
    ctx.beginPath(); ctx.move(to: first); for p in points.dropFirst() { ctx.addLine(to: p) }
    ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
}
func text(_ value: String, _ rect: CGRect, size: CGFloat, color c: NSColor = white, align: NSTextAlignment = .left) {
    let font = NSFont(name: "PingFangSC-Medium", size: size)!
    let style = NSMutableParagraphStyle(); style.alignment = align
    ctx.saveGState(); ctx.translateBy(x: rect.minX, y: rect.maxY); ctx.scaleBy(x: 1, y: -1)
    (value as NSString).draw(in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height), withAttributes: [.font: font, .foregroundColor: c, .paragraphStyle: style])
    ctx.restoreGState()
}
func dial(_ x: CGFloat, _ y: CGFloat, _ d: CGFloat, speed: String, gear: String, range: String, accent: NSColor, state: String? = nil) {
    let s = d / 240, center = CGPoint(x: x+d/2, y:y+d/2)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width:0,height:5), blur:18, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    box(CGRect(x:x,y:y,width:d,height:d), color(0.02,0.03,0.04,0.92), radius:d/2)
    ctx.restoreGState()
    ctx.setStrokeColor(color(0.29,0.35,0.39,0.65).cgColor); ctx.setLineWidth(1.5*s)
    ctx.strokeEllipse(in: CGRect(x:x+1,y:y+1,width:d-2,height:d-2))
    ctx.setStrokeColor(color(0.12,0.16,0.18).cgColor); ctx.setLineWidth(3*s)
    ctx.strokeEllipse(in: CGRect(x:x+10*s,y:y+10*s,width:d-20*s,height:d-20*s))
    ctx.beginPath(); ctx.addArc(center:center,radius:d/2-10*s,startAngle:-1.95,endAngle:-1.19,clockwise:false)
    ctx.setStrokeColor(accent.cgColor);ctx.setLineWidth(3*s);ctx.setLineCap(.round);ctx.strokePath()
    // Range icon and range share a quiet top line, separate from the speed.
    box(CGRect(x:x+64*s,y:y+45*s,width:23*s,height:10*s),.clear,radius:2*s,stroke:muted,width:1.2*s)
    box(CGRect(x:x+67*s,y:y+48*s,width:14*s,height:4*s),accent,radius:0.5*s)
    box(CGRect(x:x+88*s,y:y+48*s,width:2*s,height:4*s),muted,radius:0.5*s)
    text(range,CGRect(x:x+96*s,y:y+36*s,width:90*s,height:28*s),size:14*s,color:muted)
    line([CGPoint(x:x+55*s,y:y+72*s),CGPoint(x:x+185*s,y:y+72*s)],color(0.25,0.29,0.31),1*s)
    text(speed,CGRect(x:x+25*s,y:y+76*s,width:190*s,height:88*s),size:66*s,color:white,align:.center)
    text("km/h",CGRect(x:x+55*s,y:y+162*s,width:130*s,height:27*s),size:13*s,color:muted,align:.center)
    let gearColor: NSColor = gear == "R" ? amber : accent
    box(CGRect(x:x+103*s,y:y+195*s,width:34*s,height:25*s),gearColor.withAlphaComponent(gear == "—" ? 0.08 : 0.16),radius:8*s)
    text(gear,CGRect(x:x+103*s,y:y+192*s,width:34*s,height:29*s),size:19*s,color:gearColor,align:.center)
    if let state = state { text(state,CGRect(x:x-40*s,y:y+d+15*s,width:d+80*s,height:32*s),size:17*s,color:white,align:.center) }
}
box(CGRect(x:0,y:0,width:W,height:H),color(0.04,0.055,0.075))
text("T–DASH   /   圆形悬浮仪表",CGRect(x:52,y:34,width:1000,height:65),size:42)
text("方案预览 01",CGRect(x:1190,y:53,width:290,height:36),size:19,color:mint,align:.right)
text("苹方-简 · 中黑体     车速优先 / 续航置顶 / 挡位置底",CGRect(x:54,y:108,width:1300,height:38),size:22,color:muted)
let map = CGRect(x:48,y:175,width:1440,height:525)
box(map,color(0.075,0.105,0.13),radius:25,stroke:color(0.18,0.23,0.27))
ctx.saveGState();ctx.addPath(CGPath(roundedRect:map,cornerWidth:25,cornerHeight:25,transform:nil));ctx.clip()
for i in 0...12 { let x=CGFloat(i)*150;line([CGPoint(x:x,y:175),CGPoint(x:x+160,y:700)],color(0.17,0.21,0.24),12) }
for i in 0...5 { let y=CGFloat(i)*112+200;line([CGPoint(x:48,y:y),CGPoint(x:1488,y:y-75)],color(0.17,0.21,0.24),10) }
line([CGPoint(x:760,y:730),CGPoint(x:760,y:495),CGPoint(x:1010,y:410),CGPoint(x:1010,y:175)],color(0.08,0.4,0.96),15)
line([CGPoint(x:760,y:730),CGPoint(x:760,y:495),CGPoint(x:1010,y:410),CGPoint(x:1010,y:175)],color(0.42,0.78,1),4)
ctx.restoreGState()
box(CGRect(x:78,y:205,width:470,height:96),color(0.035,0.16,0.145),radius:20)
text("↱  800 米后右转",CGRect(x:104,y:224,width:418,height:54),size:32)
box(CGRect(x:78,y:587,width:382,height:78),color(0.025,0.04,0.055,0.94),radius:20)
text("17 分钟   9.7 公里",CGRect(x:103,y:602,width:330,height:42),size:26)
dial(1194,215,246,speed:"120",gear:"D",range:"426 km",accent:mint)
text("横屏摆放示意 · 直径约 156 pt，可拖动避让导航提示",CGRect(x:546,y:642,width:890,height:35),size:19,color:muted,align:.right)
text("同一套布局，状态只做克制的颜色变化",CGRect(x:54,y:742,width:1150,height:43),size:26)
dial(110,818,216,speed:"120",gear:"D",range:"426 km",accent:mint,state:"行驶 · 三位数独立留白")
dial(476,818,216,speed:"4",gear:"R",range:"426 km",accent:amber,state:"倒车 · 琥珀色挡位")
dial(842,818,216,speed:"0",gear:"P",range:"426 km",accent:muted,state:"驻车 · 保留速度主位")
dial(1208,818,216,speed:"—",gear:"—",range:"— km",accent:muted,state:"断连 · 清空旧读数")
line([CGPoint(x:54,y:1112),CGPoint(x:1482,y:1112)],color(0.18,0.23,0.27),1)
text("长按设置   ·   三连点锁定 / 解锁   ·   无常驻按钮",CGRect(x:54,y:1138,width:1400,height:39),size:24)
text("设计示意 / 模拟数据。AP、盲区、胎压等状态，在对应车辆信号接入并验证后扩展。",CGRect(x:54,y:1204,width:1430,height:34),size:17,color:muted)
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using:.png, properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
