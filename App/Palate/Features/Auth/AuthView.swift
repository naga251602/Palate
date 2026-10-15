import SwiftUI
import Combine

// MARK: - Keyboard height publisher
extension Publishers {
    static var keyboardHeight: AnyPublisher<CGFloat, Never> {
        let willShow = NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .map { ($0.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0 }
        let willHide = NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .map { _ in CGFloat(0) }
        return MergeMany(willShow, willHide).eraseToAnyPublisher()
    }
}

enum AuthStep { case credentials, otp }

struct AuthView: View {
    var onAuthenticated: (String) -> Void  // passes display name

    @State private var isLoginMode = true
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isLoading = false
    @State private var authStep: AuthStep = .credentials
    @State private var otpDigits = ["", "", "", "", "", ""]
    @State private var keyboardHeight: CGFloat = 0
    @FocusState private var otpFocusedIndex: Int?

    var body: some View {
        ZStack {
            GeometryReader { geo in
                AsyncImage(url: URL(string: "https://images.unsplash.com/photo-1514933651103-005eec06c04b?q=80&w=800&auto=format&fit=crop")) { img in
                    img.resizable().scaledToFill()
                } placeholder: { Color.surface }
                .frame(width: geo.size.width, height: geo.size.height).clipped().opacity(0.4)

                LinearGradient(stops: [
                    .init(color: Color.appBg.opacity(0.15), location: 0),
                    .init(color: Color.appBg.opacity(0.92), location: 0.45),
                    .init(color: Color.appBg, location: 1.0),
                ], startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                Group {
                    if authStep == .credentials {
                        credentialsContent
                            .transition(.asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    } else {
                        otpContent
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            ))
                    }
                }
                .padding(.horizontal, 28)
                Spacer().frame(height: keyboardHeight > 0 ? max(keyboardHeight - 240, 24) : 32)
            }
            .onTapGesture { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: keyboardHeight)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: authStep)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showError)
        .onReceive(Publishers.keyboardHeight) { h in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { keyboardHeight = h }
        }
    }

    // MARK: - Credentials
    private var credentialsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Palate.")
                    .font(.system(size: 48, weight: .black)).foregroundColor(.white).tracking(-1)
                Text("Your culinary journey, perfectly tracked\nand beautifully organized.")
                    .font(.system(size: 13, weight: .medium)).foregroundColor(.gray).lineSpacing(4)
            }
            .padding(.bottom, 28)

            if showError {
                errorBanner.padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            VStack(spacing: 12) {
                if !isLoginMode {
                    GlassInputField(icon: "person", placeholder: "Username (optional)", text: $username)
                }
                GlassInputField(icon: "envelope", placeholder: "Email address", text: $email)
                GlassInputField(icon: "lock.fill", placeholder: "Password", text: $password, isSecure: true)
            }
            .padding(.bottom, 16)

            Button(action: handleAuth) {
                HStack {
                    if isLoading { ProgressView().tint(Color.appBg).scaleEffect(0.8) }
                    else {
                        Text(isLoginMode ? "Sign In" : "Create Account")
                            .font(.system(size: 16, weight: .black)).foregroundColor(Color.appBg)
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Color.white.opacity(0.15), radius: 20)
            }
            .disabled(isLoading || email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            .padding(.bottom, 20)

            HStack(spacing: 4) {
                Text(isLoginMode ? "Don't have an account?" : "Already have an account?")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.gray)
                Button(action: { withAnimation { isLoginMode.toggle(); showError = false } }) {
                    Text(isLoginMode ? "Register" : "Sign In")
                        .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - OTP
    private var otpContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation { authStep = .credentials; showError = false } }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left").font(.system(size: 13, weight: .semibold))
                    Text("Back").font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.gray)
            }
            .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 6) {
                Text("Check your email")
                    .font(.system(size: 32, weight: .black)).foregroundColor(.white).tracking(-0.5)
                Text("We sent a 6-digit code to\n**\(email)**")
                    .font(.system(size: 13)).foregroundColor(.gray).lineSpacing(4)
            }
            .padding(.bottom, 36)

            HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { idx in
                    OTPDigitField(digit: $otpDigits[idx], index: idx, allDigits: $otpDigits, focusedIndex: $otpFocusedIndex)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 28)

            if showError {
                errorBanner.padding(.bottom, 14).transition(.opacity)
            }

            Button(action: handleVerifyOTP) {
                HStack {
                    if isLoading { ProgressView().tint(Color.appBg).scaleEffect(0.8) }
                    else {
                        Text("Verify & Sign In")
                            .font(.system(size: 16, weight: .black)).foregroundColor(Color.appBg)
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
                .background(otpFilled ? Color.white : Color.white.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: otpFilled ? Color.white.opacity(0.15) : .clear, radius: 20)
            }
            .disabled(!otpFilled || isLoading)
            .padding(.bottom, 20)

            HStack(spacing: 4) {
                Text("Didn't receive a code?").font(.system(size: 12)).foregroundColor(.gray)
                Button(action: resendOTP) {
                    Text("Resend").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear { otpFocusedIndex = 0 }
    }

    private var errorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 14))
            Text(errorMessage).font(.system(size: 11, weight: .bold))
        }
        .foregroundColor(Color(hex: "#F87171"))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color(hex: "#EF4444").opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#EF4444").opacity(0.3), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    var otpFilled: Bool { otpDigits.allSatisfy { $0.count == 1 } }

    // MARK: - Actions (wired to Supabase)

    func handleAuth() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmedEmail.isEmpty, !password.isEmpty else { return }
        withAnimation { showError = false; isLoading = true }
        Task {
            do {
                if isLoginMode {
                    try await SupabaseClient.shared.signInWithPassword(email: trimmedEmail, password: password)
                } else {
                    try await SupabaseClient.shared.signUpWithPassword(
                        email: trimmedEmail, password: password, username: username
                    )
                }
                // Send OTP for 2FA — SMTP now configured
                try await SupabaseClient.shared.sendOTP(email: trimmedEmail)
                await MainActor.run {
                    isLoading = false
                    withAnimation { authStep = .otp }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    SupabaseClient.shared.clearPendingSession()
                    errorMessage = error.localizedDescription
                    withAnimation { showError = true }
                }
            }
        }
    }

    func resendOTP() {
        let trimmed = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return }
        Task { try? await SupabaseClient.shared.sendOTP(email: trimmed) }
    }

    func handleVerifyOTP() {
        let code = otpDigits.joined()
        guard code.count == 6 else { return }
        withAnimation { isLoading = true; showError = false }
        Task {
            do {
                let resp = try await SupabaseClient.shared.verifyOTP(email: email, token: code)
                let displayName = resp.user?.email?.components(separatedBy: "@").first ?? "there"
                // Upload any push token captured before login
                NotificationManager.shared.uploadPendingTokenIfNeeded()
                await MainActor.run {
                    isLoading = false
                    onAuthenticated(displayName)
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "Invalid code — please try again."
                    otpDigits = ["", "", "", "", "", ""]
                    withAnimation { showError = true }
                    otpFocusedIndex = 0
                }
            }
        }
    }
}

// MARK: - OTP Digit Field
struct OTPDigitField: View {
    @Binding var digit: String
    let index: Int
    @Binding var allDigits: [String]
    @FocusState.Binding var focusedIndex: Int?

    var isFocused: Bool { focusedIndex == index }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.surface)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isFocused ? Color.white.opacity(0.5) : Color.white.opacity(0.08), lineWidth: isFocused ? 2 : 1.5))
                .shadow(color: isFocused ? Color.white.opacity(0.12) : .clear, radius: 8)

            if digit.isEmpty {
                Text("·").font(.system(size: 24, weight: .bold)).foregroundColor(.gray.opacity(0.5))
            } else {
                Text("•").font(.system(size: 22, weight: .black)).foregroundColor(.white)
            }

            TextField("", text: $digit)
                .keyboardType(.numberPad)
                .focused($focusedIndex, equals: index)
                .opacity(0.001)
                .onChange(of: digit) { old, new in
                    if new.count > 1 {
                        let nums = new.filter { $0.isNumber }
                        for (i, ch) in nums.prefix(6 - index).enumerated() { allDigits[index + i] = String(ch) }
                        digit = String(nums.prefix(1))
                        focusedIndex = min(index + nums.count, 5)
                    } else if new.count == 1 && new.first?.isNumber == true {
                        digit = new
                        if index < 5 { focusedIndex = index + 1 }
                    } else if new.isEmpty && !old.isEmpty {
                        digit = ""
                        if index > 0 { focusedIndex = index - 1 }
                    } else {
                        digit = old.filter { $0.isNumber }
                    }
                }
        }
        .frame(height: 56)
        .onTapGesture { focusedIndex = index }
    }
}

// MARK: - Glass Input Field
struct GlassInputField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName).font(.system(size: 14)).foregroundColor(.gray).frame(width: 16)
            if isSecure {
                SecureField(placeholder, text: $text)
                    .font(.system(size: 14, weight: .medium)).foregroundColor(.white).tint(.white)
            } else {
                TextField(placeholder, text: $text)
                    .font(.system(size: 14, weight: .medium)).foregroundColor(.white).tint(.white)
                    .autocapitalization(.none).disableAutocorrection(true)
                    .keyboardType(keyboardType)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 17)
        .background(Color.surface.opacity(0.65))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    var iconName: String {
        switch icon {
        case "envelope": return "envelope"
        case "person":   return "person"
        default:         return icon
        }
    }
}
