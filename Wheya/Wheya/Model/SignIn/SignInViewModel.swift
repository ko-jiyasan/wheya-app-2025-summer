//
//  SignInViewModel.swift
//  Wheya
//

import Foundation
import CloudKit
import AuthenticationServices

@Observable
class SignInViewModel {
    
    // サインイン中かどうか
    var isLoading = false
    // エラーメッセージ
    var errorMessage: String?
    var errorKind: AppErrorKind? = nil
    
    // 認証情報を保持するセッション
    private let session: Session
    
    // セッションを受け取って初期化
    init(session: Session) {
        self.session = session
    }
    
    /// Apple サインイン完了時に呼び出す
    func handleAppleSignIn(result: Result<ASAuthorization, Error>) {
        Task { await processAuthorization(result) }
    }
    
    /// 既存ユーザーの認証状態を再チェック
    func recheckAuthorization() async {
        guard let userID = session.appleUserID else { return }
        let provider = ASAuthorizationAppleIDProvider()
        
        do {
            // 現在の認証ステートを取得
            let state = try await provider.credentialState(forUserID: userID)
            switch state {
            case .authorized:
                // Still valid – keep user in and re-verify iCloud/zone
                session.isLoggedIn = true
                Task { await self.verifyCloudKitAccount() }
                
            case .revoked, .notFound, .transferred:
                // Token invalid – sign out locally and show a sign-in popup
                session.appleUserID = nil
                session.isLoggedIn = false
                errorKind = .authRevoked   // UI maps this to "Sign-In Failed / Please sign in again."
                
            @unknown default:
                session.appleUserID = nil
                session.isLoggedIn = false
                errorKind = .appleUnknown
            }
        } catch {
            // Couldn’t check credential state – be safe and sign out
            session.appleUserID = nil
            session.isLoggedIn = false
            errorKind = .appleUnknown
        }
    }
    
    /// CloudKit account status check
    @MainActor
    func verifyCloudKitAccount() async {
        let container = CloudManager.container
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                // Proceed to initialize the zone
                do {
                    _ = try await CloudKitZoneManager.shared.getPrivateZone()
                } catch {
                    self.errorKind = .genericCloud
                    self.errorMessage = "Zone setup failed: \(error.localizedDescription)"
                    self.session.isLoggedIn = false
                    return
                }
            case .noAccount:
                self.errorKind = .noICloud
                self.errorMessage = "❌ No iCloud account found."
                self.session.isLoggedIn = false
            case .restricted:
                self.errorKind = .genericCloud
                self.errorMessage = "⛔️ iCloud access is restricted."
                self.session.isLoggedIn = false
            case .couldNotDetermine:
                self.errorKind = .genericCloud
                self.errorMessage = "❓ Could not determine iCloud account status."
                self.session.isLoggedIn = false
            case .temporarilyUnavailable:
                self.errorKind = .genericCloud
                self.errorMessage = "🔌 iCloud is temporarily unavailable."
                self.session.isLoggedIn = false
            @unknown default:
                self.errorKind = .appleUnknown
                self.errorMessage = "⚠️ Unknown iCloud account status."
                self.session.isLoggedIn = false
            }
        } catch {
            self.errorKind = .genericCloud
            self.errorMessage = "🚨 CloudKit error: \(error.localizedDescription)"
            self.session.isLoggedIn = false
        }
    }
    
    /// Apple からの認証結果を処理
    @MainActor
    private func processAuthorization(_ result: Result<ASAuthorization, Error>) async {
        // Prevent double runs if something else calls this while in-flight
        if isLoading { return }

        // Start fresh (avoid showing a stale popup on next render)
        errorKind = nil
        errorMessage = nil
        
        isLoading = true
        defer { isLoading = false }
        
        switch result {
        case .success(let auth):
            // AppleID のクレデンシャルを取得
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else {
                errorKind = .genericCloud
                errorMessage = "Unexpected credential type"
                return
            }
            
            // ユーザーID と表示名を取り出し
            let id = credential.user
            let fullName = credential.fullName?.formatted() ?? ""
            session.appleUserID = id
            
            // Fetch the token to be able to delete user in the future
            do {
                try await  Task.detached(priority: .userInitiated) {
                    try await AppBackend.shared.registerSIWA(
                        appleUserID: id,
                        authorizationCode: credential.authorizationCode, // Data?
                        identityToken: credential.identityToken,         // Data? (JWT string)
                        fullName: fullName.isEmpty ? nil : fullName
                    )
                }.value
            } catch {
                // Keep silent per your UX policy (don’t block sign in on backend blips)
            }
            
            // CloudKit 上でユーザー情報を取得または新規作成
            await verifyCloudKitAccount() // Creating a zone + account check here
            await fetchOrCreateUser(fullName: fullName, appleID: id)
            
        case .failure(let error):
            // サインイン失敗時のエラー表示
            // If user dismissed the Apple sheet: it is silent 
            if let e = error as? ASAuthorizationError {
                switch e.code {
                case .canceled, .failed, .unknown:
                    // User closed the sheet or “auth already in progress”.
                    // Treat as non-fatal and stay silent.
                    return
                default:
                    break
                }
            }
            // Any other Apple error
            errorKind = .appleUnknown
            errorMessage = "Apple Sign-In failed: \(error.localizedDescription)"
        }
    }
    
    /// CloudKit から既存ユーザーを取得、なければ新規レコードを作成
    @MainActor
    private func fetchOrCreateUser(fullName: String, appleID: String) async {
        let db = CloudManager.privateDB
        let rid = CKRecord.ID(recordName: appleID)
        
        do {
            // 既存レコードをフェッチ
            let record = try await db.record(for: rid)
            let currentName = record["displayName"] as? String ?? ""
            
            // If empty → set from Apple fullName or "Anonymous"
            if currentName.isEmpty {
                let fallback = fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Anonymous" : fullName
                record["displayName"] = fallback as CKRecordValue
                _ = try await db.save(record)
            } else if !fullName.isEmpty && fullName != currentName {
                // Update to Apple's latest full name
                record["displayName"] = fullName as CKRecordValue
                _ = try await db.save(record)
            }
        } catch let ckErr as CKError where ckErr.code == .unknownItem {
            // レコードが存在しない場合は新規作成
            let newRecord = CKRecord(recordType: "UserProfile", recordID: rid)
            newRecord["displayName"] = fullName as CKRecordValue
            newRecord["appleUserID"] = appleID as CKRecordValue
            newRecord["displayName"] = fullName as CKRecordValue
            do {
                _ = try await db.save(newRecord)
                session.requiresProfileName = true
            } catch {
                errorKind = .genericCloud
                session.isLoggedIn = false
                errorMessage = "Failed to save new user record: \(error.localizedDescription)"
                return
            }
            
        } catch {
            // その他のエラー
            errorKind = .genericCloud
            session.isLoggedIn = false
            errorMessage = "CloudKit error: \(error.localizedDescription)"
            return
        }
        
        // 処理成功でログイン状態を true に
        session.isLoggedIn = true
    }
}
