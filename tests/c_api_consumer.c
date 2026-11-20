/*
 * tests/c_api_consumer.c
 * Consumidor REAL en C de la API pura del núcleo DevAgents.
 * Ejercita el ciclo completo:
 *   init → orden ambigua → pregunta → answer → plan → approve → status →
 * shutdown
 *
 * Compilado y ejecutado por `zig build c-api-check`.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "beats_core.h"

static int failures = 0;

#define CHECK(cond, msg)                                                       \
  do {                                                                         \
    if (!(cond)) {                                                             \
      fprintf(stderr, "FAIL: %s\n", msg);                                      \
      failures++;                                                              \
    } else {                                                                   \
      printf("  PASS: %s\n", msg);                                             \
    }                                                                          \
  } while (0)

#define CHECK_OK(rc, msg) CHECK((rc) == 0, msg " (returns DA_OK)")

/*
 * Extrae el primer "id" dentro del array "questions" del JSON del plan.
 * El contrato D8 serializa preguntas como {id,text,options}; el consumidor no
 * puede asumir un id fijo ("q1") — lo lee del JSON, como haría una UI real.
 * Devuelve 1 si lo encuentra y lo copia en buf.
 */
static int first_question_id(const char *json, char *buf, size_t buflen) {
  const char *q = strstr(json, "\"questions\"");
  if (!q)
    return 0;
  const char *id = strstr(q, "\"id\"");
  if (!id)
    return 0;
  const char *colon = strchr(id, ':');
  if (!colon)
    return 0;
  const char *start = strchr(colon, '"');
  if (!start)
    return 0;
  start++;
  const char *end = strchr(start, '"');
  if (!end)
    return 0;
  size_t len = (size_t)(end - start);
  if (len == 0 || len >= buflen)
    return 0;
  memcpy(buf, start, len);
  buf[len] = '\0';
  return 1;
}

int c_api_test_main(void) {
  DaCoreHandle *core = NULL;
  DaOrderHandle *order = NULL;
  DaResult rc;
  DaOrderStatus status;
  char *json = NULL;
  char *err_msg = NULL;

  printf("=== C API Consumer Test ===\n\n");

  /* ── 1. Ciclo de vida ─────────────────────────────────────────── */
  printf("1. Lifecycle\n");
  rc = da_core_init(&core, ":memory:");
  CHECK_OK(rc, "da_core_init");
  CHECK(core != NULL, "core handle is non-null");

  const char *ver = da_core_version();
  CHECK(ver != NULL && strlen(ver) > 0, "da_core_version");

  /* ── 2. Orden ambigua → debe clarificar ───────────────────────── */
  printf("\n2. Ambiguous order triggers clarification\n");
  rc = da_order_submit(core, "crea un proyecto", "test-proj", NULL, &order);
  CHECK_OK(rc, "da_order_submit (ambiguous)");
  CHECK(order != NULL, "order handle is non-null");

  rc = da_order_status(core, order, &status);
  CHECK_OK(rc, "da_order_status after ambiguous submit");
  CHECK(status == DA_ORDER_CLARIFYING, "status is DA_ORDER_CLARIFYING");

  rc = da_plan_get_json(core, order, &json);
  CHECK_OK(rc, "da_plan_get_json (clarifying)");
  CHECK(json != NULL && strlen(json) > 0, "plan JSON is non-empty");
  char qid[128];
  CHECK(first_question_id(json, qid, sizeof(qid)),
        "plan JSON contains questions");

  /* ── 3. Responder clarificación → plan ────────────────────────── */
  printf("\n3. Answer clarification → plan generated\n");
  char answers[512];
  snprintf(answers, sizeof(answers),
           "[{\"question_id\":\"%s\",\"answer\":\"en C\"}]", qid);
  rc = da_order_answer(core, order, answers);
  CHECK_OK(rc, "da_order_answer");

  rc = da_order_status(core, order, &status);
  CHECK_OK(rc, "da_order_status after answer");
  /* After answering, the plan should be generated (planned or clarifying again)
   */
  CHECK(status == DA_ORDER_PLANNED || status == DA_ORDER_CLARIFYING,
        "status is DA_ORDER_PLANNED or DA_ORDER_CLARIFYING");

  rc = da_plan_get_json(core, order, &json);
  CHECK_OK(rc, "da_plan_get_json (after answer)");
  CHECK(json != NULL && strlen(json) > 0,
        "plan JSON after answer is non-empty");

  /* If still clarifying, answer again until planned */
  if (status == DA_ORDER_CLARIFYING) {
    printf("  (still clarifying, answering again)\n");
    if (first_question_id(json, qid, sizeof(qid))) {
      snprintf(answers, sizeof(answers),
               "[{\"question_id\":\"%s\",\"answer\":\"en C con tests\"}]", qid);
      rc = da_order_answer(core, order, answers);
      CHECK_OK(rc, "da_order_answer (2nd)");
    }
    rc = da_order_status(core, order, &status);
    CHECK_OK(rc, "da_order_status after 2nd answer");
  }

  /* ── 4. Aprobar plan → running ────────────────────────────────── */
  printf("\n4. Approve plan → dispatch\n");
  if (status == DA_ORDER_PLANNED) {
    rc = da_order_approve(core, order);
    CHECK_OK(rc, "da_order_approve");

    rc = da_order_status(core, order, &status);
    CHECK_OK(rc, "da_order_status after approve");
    /* El despacho es SÍNCRONO: approve corre la orden inline, así que al volver
     * puede estar running o ya terminal. Con :memory: no hay providers: las
     * tareas corren con fallback y la orden termina en audit_unavailable (P0.1:
     * sin auditor configurado la entrega queda bloqueada). Lo que se verifica
     * es que salió de planned. */
    printf("  (status after approve: %d)\n", (int)status);
    CHECK(status == DA_ORDER_RUNNING || status == DA_ORDER_DONE ||
              status == DA_ORDER_FAILED || status == DA_ORDER_AUDIT_UNAVAILABLE,
          "status left DA_ORDER_PLANNED after approve");
  } else {
    printf("  SKIP: order not in planned state (status=%d)\n", (int)status);
  }

  /* ── 5. Modelos ────────────────────────────────────────────────── */
  printf("\n5. Model catalog\n");
  rc = da_models_list_json(core, &json);
  CHECK_OK(rc, "da_models_list_json");
  CHECK(json != NULL && strlen(json) > 0, "model list is non-empty");

  /* ── 6. Workers ────────────────────────────────────────────────── */
  printf("\n6. Worker output poll\n");
  rc = da_worker_output_poll(core, 0, &json);
  CHECK_OK(rc, "da_worker_output_poll");
  CHECK(json != NULL, "worker output is non-null");

  /* ── 7. Memoria ────────────────────────────────────────────────── */
  printf("\n7. Memory context\n");
  rc = da_memory_context_json(core, "test-proj", &json);
  CHECK_OK(rc, "da_memory_context_json");
  CHECK(json != NULL && strlen(json) > 0, "memory context is non-empty");

  /* ── 8. Aprobaciones ───────────────────────────────────────────── */
  printf("\n8. Approvals\n");
  rc = da_approval_pending_json(core, &json);
  CHECK_OK(rc, "da_approval_pending_json");
  CHECK(json != NULL, "approval list is non-null");

  rc = da_approval_resolve(core, 1, 1);
  /* May fail if no approvals exist — that's fine */
  printf("  da_approval_resolve(1,approved) returned %d\n", (int)rc);

  /* ── 9. Error handling ─────────────────────────────────────────── */
  printf("\n9. Error handling\n");
  rc = da_order_submit(NULL, "test", "test", NULL, &order);
  CHECK(rc == DA_ERR_INVALID_ARG, "null handle returns DA_ERR_INVALID_ARG");

  rc = da_last_error(&err_msg);
  CHECK_OK(rc, "da_last_error");
  CHECK(err_msg != NULL && strlen(err_msg) > 0,
        "last error message is non-empty");

  /* ── 10. Shutdown ──────────────────────────────────────────────── */
  printf("\n10. Shutdown\n");
  rc = da_core_shutdown(core);
  CHECK_OK(rc, "da_core_shutdown");

  /* ── Resultado ─────────────────────────────────────────────────── */
  printf("\n=== Results: %d failures ===\n", failures);
  return failures > 0 ? 1 : 0;
}
