# JCV Watermarker — Flutter (Windows)

App desktop escrito em **Flutter/Dart**. A composição das imagens é feita em
Dart puro (pacote `image`) dentro de um isolate; os textos são rasterizados
pelo motor de texto do Flutter (fontes do sistema) e compostos como PNG.

## Estrutura

```
flutter_app/
├── pubspec.yaml
└── lib/
    ├── main.dart            # app + tema (desktop: sem ripple, denso)
    ├── home_page.dart       # toda a UI e o fluxo
    ├── watermark_engine.dart# composição em Dart (roda em isolate via compute)
    └── models.dart
```

> A pasta `windows/` **não** fica no repositório — ela é gerada pelo CI com
> `flutter create` antes do build (veja `.github/workflows/flutter-build.yml`).

## Como buildar

### Pela nuvem (GitHub Actions) — recomendado
O workflow **Build Windows app** roda sozinho a cada push nesta branch (ou
manualmente em *Actions → Run workflow*) e publica `JCV-Watermarker-Windows.zip`
na release `windows-latest`.

### Localmente (Windows com Flutter instalado)
```bash
cd flutter_app
flutter create --platforms=windows --org com.tekz --project-name photo_watermark .
flutter pub get
flutter run -d windows
# ou: flutter build windows --release
```
