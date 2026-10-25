# Changelog

Todos os SDKs do KUAA saem com a mesma versão; as mudanças de cada uma também estão nas [releases de kuaa-io/sdk](https://github.com/kuaa-io/sdk/releases). Esta versão (0.2.0) foi gerada a partir do contrato da API 1.0.0.

## 0.2.0

- Consultas de CPF e CNPJ fora de um case: `lookups.person`, `lookups.business` e `lookups.get`, com `status` (`regular`, `irregular`, `inconclusive` ou `failed`), `reasons`, os dados, a origem de cada campo (`provenance`), a triagem nas listas do KUAA e o custo, com os créditos cobrados (`cost.credits`).
- Leitura do chip do documento (`caseChipChallenges.create`, `caseChipReads.create`) e disponibilidade dos engines (`health.get`).
- `handoff` nos links de captura.

## 0.1.0

- Primeira versão: cases, partes, sociedade e beneficiários finais, documentos, links de captura, envio de imagens, tags, webhooks, workflows, perfis de parte e créditos.
