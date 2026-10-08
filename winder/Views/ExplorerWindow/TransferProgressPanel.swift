import SwiftUI

/// 복사·이동 진행 패널 — 창 오른쪽 아래에 작업마다 카드 하나씩 쌓인다.
///
/// 붙여넣기·끌어다 놓기·트리로 떨어뜨리기 모두 FileOperationService를 거치므로 여기 한곳에 모인다.
/// 모달 시트를 띄우지 않아 복사하는 동안에도 다른 폴더를 계속 볼 수 있다 (Finder와 같은 방식).
struct TransferProgressPanel: View {
    private let center = FileTransferCenter.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: FluentMetrics.paddingS) {
            ForEach(center.visibleTransfers) { transfer in
                TransferCard(transfer: transfer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(FluentMetrics.paddingL)
        .animation(.easeOut(duration: FluentMetrics.animStandard), value: center.visibleTransfers.map(\.id))
    }
}

private struct TransferCard: View {
    let transfer: FileTransfer

    var body: some View {
        HStack(alignment: .top, spacing: FluentMetrics.paddingM) {
            Image(systemName: transfer.kind == .copy ? FluentIcons.transferCopy : FluentIcons.transferMove)
                .font(.system(size: 18))
                .foregroundStyle(Color.fluentAccent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: FluentMetrics.paddingXS) {
                Text(title)
                    .fluentBody()
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("대상: \(transfer.destinationName)")
                    .fluentCaption()
                    .foregroundColor(.fluentTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let fraction = transfer.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else {
                    // 전체 크기를 세는 중 — 폴더가 크면 몇 초 걸린다
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                Text(detail)
                    .fluentCaption()
                    .foregroundColor(.fluentTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .monospacedDigit()

                // 속도·남은 시간·현재 파일은 한 줄에 다 넣으면 파일 이름이 잘려 나간다 — 줄을 나눈다
                if let status {
                    Text(status)
                        .fluentCaption()
                        .foregroundColor(.fluentTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .monospacedDigit()
                }
            }

            Button {
                transfer.cancel()
            } label: {
                Image(systemName: FluentIcons.close)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.fluentTextSecondary)
            .disabled(transfer.isCancelling)
            .help("취소")
        }
        .padding(FluentMetrics.paddingM)
        .frame(width: FluentMetrics.transferPanelWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: FluentMetrics.cornerRadiusPanel))
        .overlay(
            RoundedRectangle(cornerRadius: FluentMetrics.cornerRadiusPanel)
                .strokeBorder(Color.fluentDivider, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private var title: String {
        let verb = transfer.kind == .copy ? "복사" : "이동"
        let what = transfer.itemCount > 1
            ? "'\(transfer.firstItemName)' 외 \(transfer.itemCount - 1)개"
            : "'\(transfer.firstItemName)'"
        return "\(what) \(verb) 중"
    }

    /// "1.20GB / 3.00GB · 245.30MB/s"
    private var detail: String {
        if transfer.isCancelling { return "취소하는 중…" }
        guard let total = transfer.totalBytes else { return "항목 크기 계산 중…" }
        var text = "\(formatFileSize(transfer.copiedBytes)) / \(formatFileSize(total))"
        if let rate = transfer.bytesPerSecond {
            text += " · \(formatFileSize(Int64(rate)))/s"
        }
        return text
    }

    /// "약 5초 남음 · part2.bin" — 아직 보여줄 것이 없으면 nil
    private var status: String? {
        guard !transfer.isCancelling, transfer.totalBytes != nil else { return nil }
        var parts: [String] = []
        if let remaining = transfer.remainingSeconds {
            parts.append(Self.remainingText(remaining))
        }
        if !transfer.currentName.isEmpty {
            parts.append(transfer.currentName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "약 5초 남음" / "약 3분 남음" / "약 1시간 20분 남음"
    private static func remainingText(_ seconds: Double) -> String {
        let s = max(1, Int(seconds.rounded()))
        if s < 60 { return "약 \(s)초 남음" }
        let minutes = (s + 30) / 60
        if minutes < 60 { return "약 \(minutes)분 남음" }
        return "약 \(minutes / 60)시간 \(minutes % 60)분 남음"
    }
}
