# PGID Authority Image

Este diretório contém o lifecycle para transformar uma VM já preparada em uma imagem OpenStack reutilizável da Autoridade Emissora:

```text
pgid-authority-v1
```

## Criar a VM base do zero

Para a VM nova que ainda vai virar snapshot, use o cloud-init de build:

```text
cloud-init-spire-instance/cloud-init/authority-build.yaml
```

Esse cloud-init clona o repositório em `/opt/spire-demo` e executa:

```bash
/opt/spire-demo/authority/scripts/bootstrap-authority-image.sh
```

Esse bootstrap instala Docker, instala SPIRE, copia `server.conf` e `agent.conf`, instala as units do core, baixa a imagem do Evidence Service e inicia `authority-core.target`.

Ele não executa o bootstrap antigo da demo e não chama:

- `configure-spire-agent.sh`;
- `configure-kv-workload.sh`;
- `configure-spire-chat-agent.sh`.

Depois que a VM base estiver validada, finalize antes do snapshot:

```bash
cd /opt/spire-demo/authority
sudo ./scripts/prepare-authority-image.sh --finalize
sudo ./scripts/check-authority-image.sh
```

## Subir a aplicação em uma VM da imagem

Em uma VM criada a partir da imagem sanitizada, use o cloud-init mínimo:

```text
cloud-init-spire-instance/cloud-init/authority-firstboot.yaml
```

Ele não reinstala SPIRE nem Docker. Ele apenas inicia o core:

```bash
sudo systemctl enable --now authority-core.target
```

O ordering esperado é:

```text
spire-server.service
  -> authority-agent-firstboot.service
  -> spire-agent.service
  -> spire-evidence-adapter.service
```

## Verificar serviços

```bash
sudo systemctl status spire-server --no-pager -l
sudo systemctl status authority-agent-firstboot --no-pager -l
sudo systemctl status spire-agent --no-pager -l
sudo systemctl status spire-evidence-adapter --no-pager -l
```

## Gerar manifesto

```bash
cd /opt/spire-demo/authority
./scripts/generate-authority-manifest.py --output authority-manifest.json
```

## Preparar VM para snapshot

Execute somente na VM que será congelada:

```bash
cd /opt/spire-demo/authority
sudo ./scripts/prepare-authority-image.sh --finalize
sudo ./scripts/check-authority-image.sh
```

`--finalize` remove o estado criptográfico/runtime do SPIRE Server e o estado do SPIRE Agent. Depois disso, crie o snapshot no OpenStack como `pgid-authority-v1`.

## UUID local do OpenStack

```bash
cd /opt/spire-demo/authority
./scripts/read-openstack-instance-uuid.py
```

Esse comando retorna apenas `instance_uuid` e `evidence_source`; ele não expõe o metadata completo do Config Drive.
