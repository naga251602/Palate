# Palate

Palate is an iPhone restaurant discovery and dining journal app. Users can explore nearby places on a map, save restaurants, record visits and dishes, manage upcoming reservations, and view profile statistics and activity. A Supabase backend provides authentication, persistence, restaurant enrichment, imports, and notifications.

## Repository layout

```text
Palate/
├── App/
│   ├── Palate.xcodeproj/         # Active Xcode project
│   ├── Palate/
│   │   ├── Application/         # Entry point, app state, tabs, root view
│   │   ├── Features/
│   │   │   ├── Auth/            # Sign-in and verification UI
│   │   │   ├── Map/             # Discovery, map, place details
│   │   │   ├── Logs/            # Dining journal and restaurant overlays
│   │   │   └── Profile/         # Profile UI
│   │   ├── Services/            # HTTP client, location, routes, notifications
│   │   ├── Shared/              # Theme, shared types and overlays
│   │   └── Assets.xcassets/     # App icon and colors
│   └── Documentation/Legacy/    # Original alternate project file, for reference
├── backend/
│   ├── supabase/
│   │   ├── config.toml         # Local services and function JWT settings
│   │   ├── migrations/         # Ordered SQL schema migrations
│   │   └── functions/          # Deno Edge Functions and shared helpers
│   ├── docs/                   # Routing and Resend setup notes
│   ├── .env.example
│   └── README.md               # Detailed backend and API reference
└── screenshots/                # 14 original PNG screenshots
```

## Architecture

The SwiftUI app uses MapKit and CoreLocation for discovery and routing, EventKit for calendar integration, and UserNotifications for notification handling. `Application/AppState.swift` coordinates app data. `Services/SupabaseClient.swift` is a lightweight Foundation/URLSession client; no Supabase Swift package is required by the supplied project.

The client communicates with Supabase Auth, database REST endpoints, and Edge Functions. The backend uses Postgres migrations and row-level security, Yelp for restaurant data, APNs for push delivery, Resend for inbound reservation emails, and Instagram import handlers. Import code also supports Gemini configuration. Shared server helpers live in `backend/supabase/functions/_shared/`.

## Run the iOS app

1. Install full Xcode with an iOS SDK compatible with the project. The app target specifies iOS 18.6; the supplied project-level settings specify 26.5. Select an installed SDK and review deployment settings in Xcode before building.
2. Open `App/Palate.xcodeproj` from this folder.
3. Set your signing team and bundle identifier on the Palate target.
4. Configure `SupabaseConfig` in `App/Palate/Services/SupabaseClient.swift` for your Supabase project. It currently contains the original project URL and public anon key. Never place a service-role key in the app.
5. Configure Location When In Use and Calendars Full Access usage descriptions in the target Info settings before exercising permission requests. The supplied active project does not include these descriptions; example wording exists in the preserved legacy project file.
6. Enable Push Notifications and configure the appropriate provisioning/entitlements for APNs on a physical device. Match the backend APNs bundle identifier to the app.
7. Select a simulator or device and run the Palate scheme.

Xcode uses a file-system-synchronized `Palate` source group, so the feature subfolders are discovered automatically. The reference project in `Documentation/Legacy/` is not the active build configuration.

## Run the backend locally

Install the Supabase CLI, Docker for local services, and Deno for function tooling. From this folder:

```sh
cd backend
cp .env.example .env
# Fill in local configuration and integration secrets.
supabase start
supabase db reset
supabase functions serve --env-file .env
```

`supabase db reset` recreates the local database and applies the ordered migrations; local data is reset. The default API is `http://localhost:54321`, and Studio is `http://localhost:54323`. Point the iOS client at the local API and its public anon key when using the local stack.

The supplied `.env.example` lists Instagram variables only. Depending on the features you use, add `YELP_API_KEY`, `RESEND_API_KEY`, `RESEND_WEBHOOK_SECRET`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, `APNS_BUNDLE_ID`, and `APNS_ENV`. Import handlers also read `GEMINI_API_KEY` and `GEMINI_MODEL`; the email handler supports `EMAIL_WEBHOOK_SECRET`. Supabase supplies its standard URL and keys to hosted functions; configure those for standalone tooling as needed. Keep private keys and service-role credentials server-side.

For a hosted project, link the intended Supabase project, review migrations, configure function secrets, and deploy deliberately. See [backend documentation](backend/README.md), [email setup](backend/docs/RESEND_SETUP_GUIDE.md), and [routing notes](backend/docs/route-guid.md). Existing backend notes describe the original integration and should be checked against the handlers and your hosting configuration before deployment.

## Backend endpoints

| Function | Purpose |
| --- | --- |
| `search-restaurants`, `restaurant-detail` | Restaurant search and enrichment |
| `log-visit`, `stats` | Dining records and statistics |
| `feed`, `notifications`, `profile-details` | Activity, notifications, profile contacts |
| `schedule-reminder`, `send-push` | Reservation reminders and APNs delivery |
| `import-email`, `import-instagram` | Reservation and social imports |

SQL migrations cover the initial schema, email/contact notifications, and Instagram imports. Authentication behavior varies by endpoint; inspect `config.toml` and each handler when configuring webhooks.

## Screenshots and maintenance

The `screenshots/` folder preserves the original filenames and images. Keep app code in `App/Palate/`, server code in `backend/supabase/`, and visual references in `screenshots/`. Keep archives outside this project folder.

This reorganization preserves Swift, TypeScript, SQL, assets, and screenshots without changing application behavior. No automated test suite is included in the supplied project. Full iOS build verification requires Xcode; backend execution requires the Supabase/Deno tooling and configured services.
# Palate
