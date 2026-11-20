#ifndef WRL_IMPLEMENTS_H
#define WRL_IMPLEMENTS_H

#include "client.h"

namespace Microsoft {
namespace WRL {

template <typename I, typename F> class CallbackImpl : public I {
public:
  F m_func;
  ULONG m_refCount = 1;

  CallbackImpl(F &&f) : m_func(std::move(f)) {}

  virtual HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                                   void **ppvObject) override {
    if (!ppvObject)
      return E_POINTER;
    *ppvObject = static_cast<I *>(this);
    AddRef();
    return S_OK;
  }

  virtual ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&m_refCount);
  }

  virtual ULONG STDMETHODCALLTYPE Release() override {
    ULONG count = InterlockedDecrement(&m_refCount);
    if (count == 0) {
      delete this;
    }
    return count;
  }

  virtual HRESULT STDMETHODCALLTYPE Invoke(HRESULT res,
                                           IUnknown *arg2) override {
    return m_func(res, arg2);
  }
};

template <typename I, typename F> ComPtr<I> Callback(F &&f) {
  return ComPtr<I>(
      reinterpret_cast<I *>(new CallbackImpl<I, F>(std::forward<F>(f))));
}

} // namespace WRL
} // namespace Microsoft

#endif // WRL_IMPLEMENTS_H
