import SwiftUI
import AppKit

struct ThumbnailView: View {
    let asset: PhotoAsset
    var thumbnail: NSImage?
    var isFocused: Bool
    var isSelected: Bool

    var body: some View {
        GeometryReader { geo in
        ZStack(alignment: .topTrailing) {
            // 图像
            if let img = thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color(nsColor: .quaternaryLabelColor))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .overlay(ProgressView().scaleEffect(0.5).tint(.secondary))
            }

            // 多选徽章
            if isSelected {
                Rectangle().fill(Color.accentColor.opacity(0.22))
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.accentColor, lineWidth: 2.5)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, Color.accentColor)
                    .font(.system(size: 18, weight: .semibold))
                    .padding(4)
            }

            // 聚焦边框环（无多选徽章时显示）
            if isFocused && !isSelected {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.accentColor, lineWidth: 2.5)
                    .padding(1)
            }

            // 视频标记
            if asset.mediaType == .video {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.5), in: Capsule())
                            .foregroundStyle(.white)
                        Spacer()
                    }.padding(4)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .animation(.easeInOut(duration: 0.1), value: isFocused)
        .animation(.easeInOut(duration: 0.1), value: isSelected)
        }
    }
}
