import SwiftUI

struct AlertContentView: View {
    let meeting: CalendarMeeting
    let onJoin: () -> Void
    let onDismiss: () -> Void

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 28) {
            Text("MEETING IN PROGRESS")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.red)
                .tracking(4)
                .opacity(pulse ? 1.0 : 0.5)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulse.toggle()
                    }
                }

            Text(meeting.title)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)

            Text("Started at \(meeting.start.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.7))

            HStack(spacing: 20) {
                Button(action: onJoin) {
                    Text(meeting.provider.joinButtonLabel)
                        .font(.system(size: 20, weight: .semibold))
                        .padding(.horizontal, 32)
                        .padding(.vertical, 16)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Text("Dismiss")
                        .font(.system(size: 20, weight: .semibold))
                        .padding(.horizontal, 32)
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.15))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
