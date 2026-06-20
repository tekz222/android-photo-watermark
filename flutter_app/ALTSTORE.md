# Instalar no iPhone/iPad via AltStore

O CI publica, a cada build, o app iOS (não assinado) e uma **fonte do AltStore**
numa GitHub Release fixa (`ios-latest`). Com isso o AltStore instala e **atualiza**
o app pela rede, e ainda **re-assina sozinho** (resolve o limite de 7 dias do
Apple ID grátis, desde que o AltServer rode no PC de vez em quando).

## Fonte do AltStore (adicione esta URL)

```
https://github.com/tekz222/android-photo-watermark/releases/download/ios-latest/apps.json
```

## Passo a passo

1. **No PC/Mac:** instale o **AltServer** (https://altstore.io). No Windows,
   instale também o **iTunes** e o **iCloud** (versões do site da Apple, não da
   Microsoft Store).
2. Conecte o iPad/iPhone por cabo, desbloqueie e toque em **Confiar**.
3. No AltServer (ícone na bandeja/menu): **Install AltStore** → escolha o
   dispositivo → faça login com seu **Apple ID** (conta grátis serve).
4. No dispositivo, abra o **AltStore**. Em **Settings**, confirme que está
   logado e que o **Background Refresh** está ligado (é o que re-assina sozinho).
5. Vá em **Browse → Sources → +** (ou o ícone de fonte) e cole a URL acima.
6. Abra a fonte **JCV Watermarker** e toque em **GET/Install**.
7. Confie no perfil: **Ajustes → Geral → VPN e Gerenciamento de Dispositivo →**
   seu Apple ID → **Confiar**.

## Manter funcionando

- Deixe o **AltServer rodando no PC** e o dispositivo na **mesma rede Wi-Fi**.
  O AltStore re-assina em segundo plano antes dos 7 dias expirarem.
- Se passar muito tempo offline, é só abrir o AltStore com o PC ligado e tocar
  em **Refresh All**.
- Quando sair um build novo, o AltStore mostra **Update** na aba do app.

> Conta Apple grátis: validade de 7 dias por assinatura (o AltStore renova
> sozinho). Conta de desenvolvedor paga ($99/ano): validade de 1 ano.
