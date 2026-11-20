#ifndef WRL_CLIENT_H
#define WRL_CLIENT_H

#include <unknwn.h>
#include <windows.h>

namespace Microsoft {
namespace WRL {

template <typename T> class ComPtr {
public:
  T *ptr_ = nullptr;

  ComPtr() : ptr_(nullptr) {}
  ComPtr(T *p) : ptr_(p) {
    if (ptr_)
      ptr_->AddRef();
  }
  ComPtr(const ComPtr &other) : ptr_(other.ptr_) {
    if (ptr_)
      ptr_->AddRef();
  }
  ~ComPtr() { Reset(); }

  void Reset() {
    if (ptr_) {
      ptr_->Release();
      ptr_ = nullptr;
    }
  }

  T *Get() const { return ptr_; }
  T **GetAddressOf() {
    Reset();
    return &ptr_;
  }
  T **ReleaseAndGetAddressOf() {
    Reset();
    return &ptr_;
  }

  T *operator->() const { return ptr_; }
  T &operator*() const { return *ptr_; }
  operator bool() const { return ptr_ != nullptr; }

  bool operator!=(std::nullptr_t) const { return ptr_ != nullptr; }
  bool operator==(std::nullptr_t) const { return ptr_ == nullptr; }

  T **operator&() { return GetAddressOf(); }

  template <typename U> HRESULT As(ComPtr<U> *out) const {
    if (!ptr_)
      return E_POINTER;
    return ptr_->QueryInterface(
        __uuidof(U), reinterpret_cast<void **>(out->ReleaseAndGetAddressOf()));
  }
};

} // namespace WRL
} // namespace Microsoft

#endif // WRL_CLIENT_H
