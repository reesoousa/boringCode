# boringCode

Fork do [Boring Notch](https://github.com/TheBoredTeam/boring.notch) (branch `dev`) que integra
recursos do [Open Island](https://github.com/Octane0411/open-vibe-island): monitorar agentes de IA
(Claude Code, Codex) no notch, aprovar ações e voltar pro terminal certo.

- **Só instalar (sem compilar):** `scripts/install.sh` (baixa o DMG da última Release; guia para agentes em
  `docs/instalar-com-ia.md`). Este arquivo é para quem vai **desenvolver**.
- **Dono:** @reesoousa (UX designer — explicar decisões técnicas em linguagem simples).
- **Licença:** GPL-3.0 (os dois projetos). Código portado do Open Island mantém crédito no
  cabeçalho do arquivo (`// Adaptado de Open Island (github.com/Octane0411/open-vibe-island), GPL-3.0`).
- **Idioma:** responder em pt-BR.

## Stack

- Swift 5/6 + SwiftUI + AppKit, projeto Xcode (`boringNotch.xcodeproj`), macOS 14+.
- App **sem sandbox** (ver "Módulo de agentes") + helper XPC (`BoringNotchXPCHelper/`)
  para trabalho privilegiado (Accessibility, brilho, notificações).
- Versão atual: **0.5.0 "Concierge Cat"** (`MARKETING_VERSION` no projeto; apelido em
  `BoringCodeRelease.name`, `AboutView.swift`).
- **Releases em pausa (decisão do dono, 2026-10-01):** a 0.5.0 é a versão distribuída. A **próxima release é a
  1.0**, um "big update". Até lá: nada de subir versão, gerar DMG, publicar Release ou appcast, mesmo com
  features novas mergeadas na `dev` (quem tem a 0.5.0 receberia a atualização sozinho). O trabalho segue em
  branches/PRs normalmente; a 1.0 só sai quando o dono pedir.
  O que vai acumulando na `dev` fica listado em `docs/1.0.md`: todo PR de correção/feature acrescenta a sua linha.
- SPM: Defaults (settings), Sparkle (updates), SkyLightWindow, Lottie, Pow, KeyboardShortcuts,
  LaunchAtLogin, swiftui-introspect, swift-collections, AsyncXPCConnection, MacroVisionKit.

## Identidade do app (não conflitar com o Boring Notch instalado)

| | Upstream | boringCode |
|---|---|---|
| Nome / executável | `Boring Notch` | `boringCode` |
| Bundle ID | `theboringteam.boringnotch` | `com.reesoousa.boringcode` |
| Helper XPC | `theboringteam.boringnotch.BoringNotchXPCHelper` | `com.reesoousa.boringcode.BoringNotchXPCHelper` |
| Sparkle feed | appcast do upstream | `https://reesoousa.github.io/boringCode/appcast.xml` (ainda não existe) |

`PRODUCT_MODULE_NAME` continua `boringNotch` (os testes usam `@testable import boringNotch`).
O nome do serviço XPC é derivado do bundle ID em `XPCHelperClient.swift`.

## Estrutura

```
boringNotch/                 # app principal
  boringNotchApp.swift       # @main + AppDelegate
  ContentView.swift          # raiz do notch: estados, hover, abas, live activities
  enums/generic.swift        # NotchState (closed/open), NotchViews (abas)
  models/                    # BoringViewModel (estado por tela), Constants.swift (Defaults.Keys)
  managers/                  # singletons: NotchWindowManager, MusicManager, Battery...
  components/
    Notch/                   # janela (BoringNotchSkyLightWindow), header, home, LiveActivityStack
    Tabs/                    # TabSelectionView (barra de abas)
    Settings/                # SettingsView + Views/
    Shelf/ Music/ Calendar/ OSD/ LiveActivities/ Webcam/ Onboarding/
BoringNotchXPCHelper/        # helper XPC
Shared/                      # protocolo XPC
boringNotchTests/
reference/open-island/       # clone SÓ LEITURA do Open Island (ignorado via .git/info/exclude)
```

Pontos de extensão para o módulo de agentes:
- **Nova aba:** case em `NotchViews` + `TabModel` em `TabSelectionView.swift` + case no switch
  de `ContentView` (conteúdo aberto).
- **Indicador no notch fechado:** novo case em `LiveActivityItem` (`components/Notch/LiveActivityStack.swift`),
  incluir em `ContentView.liveActivities` e na largura do "chin".
- **Alertas transitórios:** `SneakContentType` / `toggleSneakPeek` em `BoringViewCoordinator`.
- **Settings:** chave em `Defaults.Keys` (`models/Constants.swift`) + aba em `SettingsView`.

## Compilar e rodar

```bash
# compilar + assinar + instalar a ÚNICA cópia em /Applications + abrir (é o fluxo padrão)
scripts/install-dev.sh            # --no-open para só instalar

# instalador (ver "Distribuição")
scripts/make-dmg.sh   # → dist/boringCode-<versão>.dmg

# testes
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -derivedDataPath build.noindex test
```

- **Nunca abrir o app de dentro de `build.noindex/`** nem copiar à mão: só existe uma cópia,
  `/Applications/boringCode.app`. O sufixo `.noindex` esconde os builds do Spotlight/Finder e o
  script tira-os do registro de apps (antes apareciam 3 "boringCode" no Finder).
- **Assinatura de dev estável:** `install-dev.sh` re-assina tudo com o certificado local
  `boringCode Dev` (criado uma vez por `scripts/setup-dev-signing.sh` no chaveiro de login,
  autoassinado, só desta máquina). Ad-hoc (`-`) muda de identidade a cada build e o macOS
  pedia Acessibilidade/Automação de novo; com o certificado a identidade é
  `identifier "com.reesoousa.boringcode" and certificate leaf = H"…"` e as permissões ficam.
  O projeto Xcode continua ad-hoc (a re-assinatura é só no script).
- Rodar junto com o Boring Notch de `/Applications` funciona, mas os dois desenham no notch —
  feche o instalado para testar visualmente.
- Projeto Xcode: ad-hoc (`CODE_SIGN_IDENTITY[sdk=macosx*] = "-"`), sem Team.
- **Release ad-hoc cai na abertura** (library validation: "different Team IDs"). Por isso o
  `make-dmg.sh` re-assina tudo com o mesmo "Apple Development" (Team ID). Ver "Distribuição".

## Regras de git

- **Nunca** commitar direto em `main` nem `dev`. Uma branch por feature: `feat/...`
  (ou `fix/...`, `chore/...`), partindo da `dev` atualizada.
- **Conventional Commits em pt-BR** (`feat: adiciona aba de agentes`).
- Commit e push livres nas branches de feature. PR → `dev` do **fork** (`reesoousa/boringCode`).
- **Sem** force-push, rebase de branch publicada ou rewrite de histórico sem perguntar.
- Remotes: `origin` = fork (`reesoousa/boringCode`), `upstream` = `TheBoredTeam/boring.notch`.
  Sincronizar: `git fetch upstream && git merge upstream/dev` (numa branch, nunca direto na `dev`).
- `reference/` nunca entra no git.

## Distribuição (DMG)

Decisão do dono (2026-09-30): **Apple ID pessoal grátis** (opção 2). Alternativas descartadas por
ora: Developer ID da empresa (sem alerta, precisa da conta paga) e
`disable-library-validation` (sem conta, menos protegido).

`scripts/make-dmg.sh`: build Release **universal** (arm64 + x86_64) → re-assina de dentro para
fora (`scripts/lib/sign-app.sh`) com a identidade "Apple Development" do chaveiro (ou
`SIGN_IDENTITY=…`) → `codesign --verify` → dmgbuild (hashes travados, venv em
`build.noindex/dmgenv`) → `dist/boringCode-<versão>.dmg` (layout `Configuration/dmg/`).

- Pré-requisitos na máquina: Apple ID em Xcode › Ajustes › Contas + certificado "Apple
  Development" (Gerenciar Certificados › +) + intermediário **Apple WWDR G3** no chaveiro
  (sem ele: "unable to build chain" / `errSecInternalComponent`; baixar de
  apple.com/certificateauthority). Team pessoal: `NPAAQDQK4Y`. Certificado vence em 1 ano.
- Sem notarização: `spctl` dá "rejected"; quem recebe libera uma vez em Ajustes › Privacidade e
  Segurança › "Abrir mesmo assim". Instruções para quem recebe: `docs/instalar.md`.
- Sempre testar **abrindo o app de dentro do DMG montado** (crash →
  `~/Library/Logs/DiagnosticReports/boringCode-*.ips`) e, depois, tirar `/Volumes/boringCode` do
  LaunchServices (o `install-dev.sh` faz isso).

- O DMG **não vai para o git** (`dist/` no `.gitignore`): é publicado como Release do GitHub
  (`gh release create v<versão> dist/boringCode-<versão>.dmg --repo reesoousa/boringCode`),
  com o SHA-256 nas notas. v0.1.0 saiu como pré-release (teste com amigos).

**Atualizações automáticas (Sparkle, desde a 0.5.0):**
- Feed `https://reesoousa.github.io/boringCode/appcast.xml` (GitHub Pages, branch `gh-pages`), em
  `SUFeedURL` **e** em `UpdateChannel.feedURLString` (o delegate do Sparkle usa este; até a 0.4.0 ele apontava
  para o appcast do Boring Notch — nunca voltar a isso, trocaria o app pelo original).
- Chave EdDSA própria no chaveiro de login, conta `boringcode` (`generate_keys --account boringcode`); a pública
  está em `SUPublicEDKey`. **Sem a chave privada não dá para publicar atualizações**: backup com
  `generate_keys --account boringcode -x <arquivo>` (guardar fora do repo).
- Lançar versão: subir `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` (build sempre maior) → `make-dmg.sh` →
  PR → merge → `gh release create` com o DMG → `scripts/publish-appcast.sh` (assina, gera o appcast com as notas
  de `dist/release-notes-v<versão>.md` e publica no `gh-pages`). Appcast só com a versão mais nova.
- `scripts/install.sh` (instalação sem compilar, usada no README e por agentes de IA) pega a Release mais nova
  pela API e procura o asset `boringCode-*.dmg`, conferindo o `digest` SHA-256 do GitHub: manter esse nome no DMG.
  Testar sem mexer no app instalado: `BORINGCODE_DIR=<pasta> scripts/install.sh --no-open` (e `HOME=<pasta falsa>`
  para testar o `--uninstall`).

Próximos passos:
1. Opcional: fundo próprio do DMG (660×400, `Configuration/dmg/.background/background.tiff`).
2. Se a empresa tiver Developer ID: trocar a identidade e adicionar notarização
   (`xcrun notarytool` + `stapler`) no `make-dmg.sh`.

## Módulo de agentes (`boringNotch/agents/`)

Decisões de produto (definidas pelo dono):
- **Aba "Agentes"** no notch aberto (ao lado de Home/Shelf). Lista sessões, aprovar/recusar, clique → foca terminal/editor.
- **Notch fechado** (prioridade sempre do layout do Boring Notch):
  - só música → capa à esquerda, espectro à direita (original).
  - música + agente → música à esquerda (interações normais), **mascote do agente no lugar do espectro**.
  - só agente → mascote à esquerda, um quadradinho por sessão à direita (cor = status; pulsa quando espera você).
  - **Aviso por baixo** (decisão do dono, 2026-10-05: "quando for algo importante, informação direto no notch"):
    aprovação/pergunta (fica até responder), terminou (resumo do `last_assistant_message`, 6 s) e erro. O notch
    cresce para baixo com mola e alarga 56 pt de cada lado. Ajuste `agentsClosedPeek`.
- **Hover nas áreas do agente** abre o notch direto na aba Agentes; esquerda/centro/arrastar arquivo = normal.
- **Perguntas (AskUserQuestion)** respondidas no notch (opções + "Outra…"); ExitPlanMode vira aprovação.
- **Nome:** tudo que o usuário vê diz "boringCode" (traduções no xcstrings, chaves iguais ao upstream).
  Sobre credita Boring Notch e Open Island.
- **Pedido de aprovação** expande o notch sozinho na aba Agentes e fecha sozinho quando resolvido.
- Tudo **ligado por padrão** (público-alvo: devs). Configurações em Ajustes › "Agentes de IA".
- **Agentes/hosts:** Claude Code (Terminal/iTerm, extensão VS Code/Cursor, app Claude) e Codex
  (CLI, VS Code, app Codex = `ChatGPT.app`, bundle `com.openai.codex`, `codex://threads/<id>`).
  Cores: Claude laranja, Codex azul.
- **Mascote em pixels** (`AgentMascot`, decisão do dono 2026-10-05: "os SVGs que o Claude usa do robozinho"):
  o Clawd do Claude Code na mesma grade da tela de boas-vindas (18×5, pixel 1:2 como meio bloco do terminal,
  arte tirada do próprio binário do Claude Code) e um bloquinho `>_` para o Codex. Pose por estado: anda (comandos),
  digita (edição), passa os olhos (leitura/busca), acena (aprovação), braço erguido (pergunta), pulinho (terminou),
  braços caídos + tremor (erro), respira e pisca parado. Estático com Reduzir movimento. Ícone da aba: `>_` (`AgentPromptGlyph`).
- **Aba Agentes = cartão de foco** (referência do dono: Coucou, github.com/Louis-CFM/coucou, MIT — sem o personagem
  Mochi): mascote à esquerda, passos do turno à direita (últimos 3: verbo + alvo, +N −M nas edições, atual com
  brilho), coluna com as outras sessões. O cartão vira o pedido: aprovação (descrição + comando + Recusar /
  Sempre permitir / Aprovar; plano = Continuar planejando / Aprovar plano), pergunta (escolha única responde no
  toque), terminou (resumo + Abrir terminal / OK) e erro. Brilho colorido na base por situação.
- **Som sutil** ao concluir (som do sistema, padrão Bottle, volume 0,35).
- **Logo** (arte-fonte em `logo/`): ícone do app (grade 824/1024), barra de menus (SVG template
  `menubarIcon`), boas-vindas. Sobre no padrão Apple: "Feito para pessoas não tão chatas assim."
- **LocalSend** no Shelf (Quick Share), abrindo o app direto; AirDrop continua padrão.
- **Guardrails de design:** seguir a linguagem visual do Boring Notch (preto, cinza, cantos 12, SF Symbols,
  mesmas geometrias de live activity). Não alterar layouts existentes além do slot do espectro.
- Strings: chave em inglês + tradução pt-BR em `Localizable.xcstrings` (script python, preservando ordem:
  `json.dumps(d, indent=2, separators=(',', ' : '), ensure_ascii=False)`, sem `sort_keys`).
  Conflitos entre branches nesse arquivo: resolver pela **união das chaves**.

Arquitetura:
- `AgentHookInstaller` (`.claude` e `.codex`) escreve `~/Library/Application Support/boringCode/bin/boringcode-hook` (sh + curl)
  e adiciona entradas em `~/.claude/settings.json` / `~/.codex/hooks.json` (+ `[features] hooks = true`
  no `config.toml`) identificadas por `boringCode/bin/boringcode-hook` (backup `*.boringcode-backup.*`,
  mantém 5). Não toca hooks de outras ferramentas. Script: `boringcode-hook <Evento> [claude|codex]`.
- O script faz `curl --unix-socket agents.sock` → `AgentHookServer` (HTTP mínimo, POSIX socket).
  `PermissionRequest` fica pendurado (timeout 86400) até aprovar/recusar; se o hook morrer
  (respondeu no terminal) o servidor detecta EOF e tira do notch. Fail-open sem o app.
  Só uma instância escuta: se o socket já responde, a outra não o toma (tenta de novo a cada 5 s,
  para assumir se a dona fechar). O app hospedeiro dos testes (`XCTestConfigurationFilePath`) não
  liga o módulo de agentes.
- `AgentSessionStore` (@MainActor) = reducer de eventos → `AgentSession` (status, passos, resumo final, TTY, PID).
  `AgentActivity.swift` traduz ferramenta → passo (`AgentStepParser`: tipo, alvo, `description` do Bash, diff +N −M
  pelo `difference(from:)`); `closedPeek` decide o aviso do notch fechado. "Sempre permitir" devolve
  `permission_suggestions` como `updatedPermissions` (só Claude; o Codex recusa). Codex continua só com os 4 hooks
  (PreToolUse nele enche o terminal de log, como o Open Island também evita).
  Poda sessões cujo PID morreu. `AgentTerminalFocus` = AppleScript por TTY / abrir pasta no VS Code.
- **App sem sandbox** (aprovado pelo dono em 2026-09-30): precisa escrever em `~/.claude`, controlar
  Terminal/iTerm e o socket (limite de 104 bytes no sun_path estoura dentro do container).
- Testar o núcleo sem o app: compilar `agents/AgentHookServer.swift`, `AgentModels.swift`,
  `AgentHookInstaller.swift` + um `main.swift` com `swiftc` e usar socket em caminho curto.
- Convive com Open Island instalado: se os dois estiverem abertos, ambos seguram o PermissionRequest.

## LocalSend integrado (`boringNotch/localsend/`)

Decisões do dono (2026-09-30): enviar e receber **sem abrir o app LocalSend**; recebidos são
**aceitos sozinhos**, vão para **Downloads** e entram no Shelf já selecionados; ao receber o notch
**abre no Shelf** com a cápsula "Recebendo/Recebido de…" no cabeçalho e fecha sozinho. AirDrop
continua o serviço padrão do Shelf (LocalSend se escolhe em Ajustes › Shelf).

- Protocolo LocalSend **v2.2** implementado do zero (compatível com o app 1.18): multicast
  `224.0.0.167:53317` (`LocalSendMulticast`, POSIX, `SO_REUSEPORT`) + busca na /24 como reserva;
  servidor HTTPS `LocalSendServer` (Network.framework, **mTLS obrigatório**, HTTP/1.1, chunked);
  `LocalSendClient` (URLSession, certificado do cliente + fingerprint fixado do outro lado).
- Identidade: RSA-2048 + certificado autoassinado montado em DER (`LocalSendIdentity`), em
  `~/Library/Application Support/boringCode/boringcode-localsend.{der,key}` (chave 0600) e
  `SecIdentityCreate` via dlsym — **fora do chaveiro** (no chaveiro o macOS pedia senha quando a
  assinatura mudava).
- Recebimento (`LocalSendReceiver`): quarentena nos arquivos, limite do tamanho declarado,
  espaço em disco, sessão expira parada (30 s), `.part` ocultos limpos na abertura.
- macOS 26+/27 pode marcar o app com `DenyMulticast` (Ajustes › Privacidade › Rede Local): aí a
  descoberta depende da busca direta/HTTP; celulares acham o Mac pela porta 53317.
- Testar sem celular: `defaults write com.reesoousa.boringcode localSendShowThisMac -bool true`
  mostra aparelhos do próprio Mac (ex.: o app LocalSend). Núcleo compila sozinho com `swiftc`
  (Models, Identity, Multicast, Server, Receiver, Client + um `main.swift`); o visual do slot sai
  em PNG com `ImageRenderer` num teste (`LocalSendSlotContent` recebe o estado pronto).

## Monitor do sistema (`boringNotch/monitor/`)

- Aba `NotchViews.monitor`, aberta pelo botão do cabeçalho (à esquerda do espelho; os dois aparecem na Home e no
  Monitor para o botão não mudar de lugar). Não entra na barra de abas.
- `SystemSampler` (actor): CPU por `host_statistics` (ticks), memória por `host_statistics64` (apps + wired +
  comprimida, como o Monitor de Atividade), bateria reaproveita `BatteryStatusViewModel` (some sem bateria interna), disco por `volumeAvailableCapacityForImportantUsage`
  (relê a cada 10 s), rede por `sysctl NET_RT_IFLIST2` (contadores de 64 bits de `en*`/`pdp_ip*`; VPN fica de fora).
- `SystemMonitor` só mede entre `begin`/`end` (onAppear/onDisappear da aba): fechado, custo zero. Escala das barras de
  rede = pico recente com decaimento (mínimo 256 KB/s).
- Visual: grade 3×2 (4 métricas → 2×2), cartões de canto 12 (`white 0.06`), número 17 pt + unidade 11 pt cinza, barra do
  player (4 pt, trilho cinza 0.3, branco). Entrada em cascata diagonal (desfoque → nítido, mola) e `CountingText`
  (Animatable) conta do zero junto com a barra; respeita Reduzir movimento. Ajustes › Monitor do sistema.

## Encaixe de janelas (`boringNotch/windowsnap/`)

Decisão do dono (2026-10-01): arrastar uma janela até o notch abre layouts para redimensioná-la, como as "Snap Zones"
do Sapphire (`github.com/cshariq/Sapphire`, **AGPL-3.0** — só a ideia; código próprio, sem copiar trechos).

- `WindowDragMonitor`: monitores globais de mouse (sem Acessibilidade). No clique guarda a janela de camada 0 sob o
  ponteiro (`CGWindowList`; o Dock tem uma janela invisível de tela inteira na camada 20, por isso só camada 0); se ela
  anda do mesmo tamanho, é arraste de janela. Perto do notch (110 ms) publica `pickerScreenUUID` → `ContentView` abre
  o notch com `WindowSnapPickerView` + `WindowSnapHeader` e fecha ao terminar (se foi o arraste que abriu).
- Durante o arraste o notch não recebe hover: o acerto das zonas é feito no monitor com `NSEvent.mouseLocation` e as
  miniaturas, que se registram como `NSView` (`ScreenRectReader`) e são convertidas para a tela na hora.
- `WindowSnapPreview`: painel transparente do tamanho da tela, `order(.below, relativeTo: janela arrastada)`, vidro
  `.hudWindow` com canto 14; desliza entre zonas com mola.
- **Quem move a janela é o helper XPC** (`BoringNotchXPCHelper/WindowMover.swift`, `moveWindow` no protocolo): a
  permissão de Acessibilidade é dele, não do app (`AXIsProcessTrusted()` no app dá false). Acha a janela por
  `_AXUIElementGetWindow` (privada), desliga `AXEnhancedUserInterface` enquanto mexe, desliza 0,24 s a 60 Hz e
  desiste do deslize se um passo passar de 30 ms. Sem permissão o cabeçalho avisa e soltar abre o pedido do sistema.
- Depois de encaixar, `holdsHoverOpen` impede o notch de reabrir por hover até o ponteiro sair (máx. 3 s).
- Testar sem mexer à mão: um executável com `CGEvent` (`leftMouseDown`/`leftMouseDragged`/`leftMouseUp` em
  `.cghidEventTap`) arrasta uma janela do Finder; `WindowMover.swift` compila sozinho com um `main.swift` para testar
  o movimento (o processo precisa de Acessibilidade).
- Layouts em `SnapLayout.all` (frações com origem em cima). Cuidado: `CGRect(x: 1 / 3, …)` escolhe o init de `Int`
  e vira 0 — usar `1.0 / 3`.

## Histórico do clipboard (`boringNotch/clipboard/`)

Decisões do dono (2026-10-02): como o Win+V do Windows. **Aba nova** na barra (Home · Shelf · Agentes · Clipboard),
**clique copia e cola** no app da frente, atalho **⌃⌘V** (abre direto na aba; de novo, fecha), **últimos 100 salvos**.

- `ClipboardHistory` (@MainActor): a cada 0,5 s compara o `changeCount` (ler o número não mostra aviso); mudou → lê
  arquivos (`public.file-url`) → imagem (png/tiff, até 25 MB, arquivo em `Clipboard/images`) → texto (com RTF até 512 KB;
  endereço sozinho vira link). Mesmo conteúdo (SHA-256) sobe para o começo em vez de repetir. Ignora tipos
  `org.nspasteboard.Concealed/Transient/AutoGeneratedType` e cópias do próprio boringCode. Disco:
  `~/Library/Application Support/boringCode/Clipboard/history.json` (pasta 0700).
- **Permissão (macOS 15.4+):** ler o clipboard de outro app mostra aviso do sistema. `accessBehavior` ≠ `.alwaysAllow`
  → não lê nada (seria um aviso por cópia); a aba/onboarding pedem com um clique (uma leitura fora da main, que põe o
  app na lista) e mandam para Privacidade e Segurança › **Colar de Outros Apps** (`?Privacy_Pasteboard`).
- **Colar:** o item volta ao clipboard e o helper aperta ⌘V (`pasteCommandV` no protocolo XPC; a Acessibilidade é do
  helper). Sem permissão ou com o ajuste desligado, só copia e o cartão mostra "Copiado". Com a busca em uso o notch
  tem o teclado (`wantsKeyForTextInput`), então o ⌘V vai por `postToPid` para o app da frente.
- Visual: cartões 124×100, cantos 12, `white 0.06` (hover 0.11 + escala 1,03, aperto 0,96); filtros como a barra de
  abas (cápsula `secondarySystemFill` com `matchedGeometryEffect`); entrada em cascata igual ao monitor. Lixeira confirma
  no próprio botão ("Limpar tudo", volta em 3 s). Modo compacto: só pelo atalho, 600×136.

## Onboarding (`components/Onboarding/`)

Decisão do dono (2026-10-01): uma tela por recurso que **pergunta se quer usar e já pede a permissão do sistema**
(`FeatureRequestView`, com pontinhos de progresso e estados pedindo / esperando nos Ajustes / pronto ✓).
Ordem: boas-vindas → agentes → janelas e controles (Acessibilidade: encaixe, notificações, volume/brilho, com
caixinhas) → LocalSend (Rede Local) → clipboard (Colar de Outros Apps) → espelho (câmera) → calendário + lembretes → visualizador (áudio, 14.2+) →
player de música → atualizações → pronto. "Agora não" desliga o recurso no `Defaults`.
- Na primeira abertura (`firstLaunch`, `@AppStorage`) os hooks dos agentes e a rede do LocalSend **não ligam
  sozinhos**: começam no "sim" da tela ou ao terminar o onboarding (`startAgentAndNetworkServices`, idempotente).
- Acessibilidade: o pedido abre o aviso do sistema; a janela do onboarding sai de `.floating` para não cobrir os
  Ajustes e a tela consulta o helper a cada 1 s até liberar.
- Rever o onboarding: `defaults write com.reesoousa.boringcode firstLaunch -bool true` e abrir o app (as escolhas
  mudam os ajustes de verdade). PNGs das telas: `NSHostingView` numa `NSWindow` + `cacheDisplay` num teste
  temporário (desenha os controles do AppKit, que o `ImageRenderer` não desenha).

