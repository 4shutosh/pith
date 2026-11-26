import PithMacCore
import SwiftUI

struct SidebarToggleIcon: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: 1, y: 2, width: size.width - 2, height: size.height - 4)
            let outline = Path(roundedRect: rect, cornerRadius: 2.5)
            context.stroke(outline, with: .foreground, lineWidth: 1.25)

            var divider = Path()
            let splitX = rect.minX + 4.5
            divider.move(to: CGPoint(x: splitX, y: rect.minY))
            divider.addLine(to: CGPoint(x: splitX, y: rect.maxY))
            context.stroke(divider, with: .foreground, lineWidth: 1.25)
        }
        .frame(width: 15, height: 15)
    }
}

struct TodayIcon: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: 1.5, y: 1.5, width: size.width - 3, height: size.height - 3)
            context.stroke(Path(roundedRect: rect, cornerRadius: 2.5), with: .foreground, lineWidth: 1.25)

            var bar = Path()
            bar.move(to: CGPoint(x: rect.minX, y: rect.minY + 3.2))
            bar.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 3.2))
            context.stroke(bar, with: .foreground, lineWidth: 1.1)

            let dot = CGRect(x: size.width / 2 - 1.25, y: rect.minY + 5.75, width: 2.5, height: 2.5)
            context.fill(Path(ellipseIn: dot), with: .foreground)
        }
        .frame(width: 14, height: 14)
    }
}

struct PagesIcon: View {
    var body: some View {
        Canvas { context, size in
            let ys: [CGFloat] = [3.5, 7, 10.5]
            let widths: [CGFloat] = [10, 10, 6.5]
            for (y, width) in zip(ys, widths) {
                var line = Path()
                line.move(to: CGPoint(x: 2, y: y))
                line.addLine(to: CGPoint(x: 2 + width, y: y))
                context.stroke(
                    line,
                    with: .foreground,
                    style: StrokeStyle(lineWidth: 1.25, lineCap: .round)
                )
            }
        }
        .frame(width: 14, height: 14)
    }
}

struct SearchIcon: View {
    var size: CGFloat = 14

    var body: some View {
        Canvas { context, canvasSize in
            let diameter = canvasSize.width * 0.62
            let circle = CGRect(x: 1.5, y: 1.5, width: diameter, height: diameter)
            context.stroke(Path(ellipseIn: circle), with: .foreground, lineWidth: 1.25)

            var handle = Path()
            let start = CGPoint(x: circle.maxX - 1.2, y: circle.maxY - 1.2)
            let end = CGPoint(x: canvasSize.width - 1.5, y: canvasSize.height - 1.5)
            handle.move(to: start)
            handle.addLine(to: end)
            context.stroke(
                handle,
                with: .foreground,
                style: StrokeStyle(lineWidth: 1.25, lineCap: .round)
            )
        }
        .frame(width: size, height: size)
    }
}

struct PlusIcon: View {
    var body: some View {
        Canvas { context, size in
            let mid = size.width / 2
            var path = Path()
            path.move(to: CGPoint(x: mid, y: 2.5))
            path.addLine(to: CGPoint(x: mid, y: size.height - 2.5))
            path.move(to: CGPoint(x: 2.5, y: mid))
            path.addLine(to: CGPoint(x: size.width - 2.5, y: mid))
            context.stroke(
                path,
                with: .foreground,
                style: StrokeStyle(lineWidth: 1.25, lineCap: .round)
            )
        }
        .frame(width: 13, height: 13)
    }
}

struct ChevronIcon: View {
    let expanded: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path()
            if expanded {
                path.move(to: CGPoint(x: 2, y: 3.5))
                path.addLine(to: CGPoint(x: 5, y: 6.5))
                path.addLine(to: CGPoint(x: 8, y: 3.5))
            } else {
                path.move(to: CGPoint(x: 3.5, y: 2))
                path.addLine(to: CGPoint(x: 6.5, y: 5))
                path.addLine(to: CGPoint(x: 3.5, y: 8))
            }
            context.stroke(
                path,
                with: .foreground,
                style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: 10, height: 10)
    }
}

struct TaskMark: View {
    let status: TaskStatus

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 1.5
            let rect = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
            let circle = Path(ellipseIn: rect)
            switch status {
            case .todo:
                context.stroke(circle, with: .foreground, lineWidth: 1.25)
            case .later:
                context.stroke(
                    circle,
                    with: .foreground,
                    style: StrokeStyle(lineWidth: 1.25, dash: [2.2, 2.2])
                )
            case .doing:
                context.stroke(circle, with: .foreground, lineWidth: 1.25)
                let inner = rect.insetBy(dx: 2.8, dy: 2.8)
                context.fill(Path(ellipseIn: inner), with: .foreground)
            case .done:
                context.fill(circle, with: .foreground)
                var check = Path()
                check.move(to: CGPoint(x: 3.8, y: 6.8))
                check.addLine(to: CGPoint(x: 5.8, y: 8.8))
                check.addLine(to: CGPoint(x: 9.4, y: 4.7))
                context.stroke(
                    check,
                    with: .color(Theme.canvas),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
                )
            case .canceled:
                context.stroke(circle, with: .foreground, lineWidth: 1.25)
                var cross = Path()
                cross.move(to: CGPoint(x: 4.5, y: 4.5))
                cross.addLine(to: CGPoint(x: 8.5, y: 8.5))
                cross.move(to: CGPoint(x: 8.5, y: 4.5))
                cross.addLine(to: CGPoint(x: 4.5, y: 8.5))
                context.stroke(
                    cross,
                    with: .foreground,
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
                )
            }
        }
        .frame(width: 13, height: 13)
    }
}

struct SunIcon: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let core = CGRect(x: center.x - 2.75, y: center.y - 2.75, width: 5.5, height: 5.5)
            context.stroke(Path(ellipseIn: core), with: .foreground, lineWidth: 1.25)
            var rays = Path()
            for step in 0..<8 {
                let angle = Double(step) * .pi / 4
                let inner = 4.6
                let outer = 6.2
                rays.move(to: CGPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
                rays.addLine(to: CGPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
            }
            context.stroke(rays, with: .foreground, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        .frame(width: 15, height: 15)
    }
}

struct MoonIcon: View {
    var body: some View {
        Canvas { context, size in
            let disc = CGRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4)
            let bite = disc.offsetBy(dx: 4, dy: -3)
            context.clip(to: Path(ellipseIn: bite), options: .inverse)
            context.fill(Path(ellipseIn: disc), with: .foreground)
        }
        .frame(width: 15, height: 15)
    }
}
