import SwiftUI

struct AlertContentView: View {
    let meetings: [CalendarMeeting]
    let onJoin: (CalendarMeeting) -> Void
    let onDismissAll: () -> Void

    @State private var pulse = false

    private var isMultiple: Bool { meetings.count > 1 }

    var body: some View {
        VStack(spacing: 28) {
            Text(isMultiple ? "MULTIPLE MEETINGS IN PROGRESS" : "MEETING IN PROGRESS")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.red)
                .tracking(4)
                .opacity(pulse ? 1.0 : 0.5)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulse.toggle()
                    }
                }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 32) {
                    ForEach(meetings) { meeting in
                        MeetingChoiceView(meeting: meeting, compact: isMultiple, onJoin: { onJoin(meeting) })
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 560)

            Button(action: onDismissAll) {
                Text(isMultiple ? "Dismiss All" : "Dismiss")
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(Color.white.opacity(0.15))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One meeting's title/time/join-button block. `compact` shrinks the type
/// scale when there's more than one on screen at once, so a handful of
/// concurrent meetings still fit without the overlay overflowing.
private struct MeetingChoiceView: View {
    let meeting: CalendarMeeting
    let compact: Bool
    let onJoin: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(meeting.title)
                .font(.system(size: compact ? 32 : 48, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)

            Text("Started at \(meeting.start.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: compact ? 16 : 20))
                .foregroundColor(.white.opacity(0.7))

            Button(action: onJoin) {
                Text(meeting.provider.joinButtonLabel)
                    .font(.system(size: compact ? 18 : 20, weight: .semibold))
                    .padding(.horizontal, compact ? 28 : 32)
                    .padding(.vertical, compact ? 14 : 16)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }
}
