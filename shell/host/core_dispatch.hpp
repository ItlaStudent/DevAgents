#ifndef BEATS_CORE_DISPATCH_HPP
#define BEATS_CORE_DISPATCH_HPP
#include "core_client.hpp"
#include <memory>
namespace beats {
// A timed-out caller releases ownership; the queued task retains it until the
// existing core worker consumes it. Stop never waits for that worker to drain.
inline CoreResult
DispatchCoreCall(const std::function<bool(std::function<void()>)> &enqueue,
                 std::function<CoreResult()> operation, HANDLE stop,
                 DWORD timeout = 4000) {
  struct Completion {
    HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    std::atomic<bool> cancelled{false};
    CoreResult result;
    ~Completion() {
      if (done)
        CloseHandle(done);
    }
  };
  auto completion = std::make_shared<Completion>();
  if (!completion->done)
    return {-1, "", "No se pudo preparar la llamada al motor"};
  if (stop && WaitForSingleObject(stop, 0) == WAIT_OBJECT_0)
    return {-1, "", "Llamada al motor cancelada"};
  if (!enqueue([completion, operation = std::move(operation)] {
        if (completion->cancelled.load())
          return;
        completion->result = operation();
        SetEvent(completion->done);
      }))
    return {-1, "", "El carril del motor está cerrado"};
  HANDLE events[] = {completion->done, stop};
  const DWORD waited =
      WaitForMultipleObjects(stop ? 2 : 1, events, FALSE, timeout);
  if (waited == WAIT_OBJECT_0)
    return completion->result;
  completion->cancelled = true;
  return {-1, "",
          waited == WAIT_TIMEOUT ? "La llamada al motor agotó el plazo"
                                 : "Llamada al motor cancelada"};
}
} // namespace beats
#endif
