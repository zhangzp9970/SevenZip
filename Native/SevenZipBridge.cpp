// Stable C boundary over the upstream 7-Zip archive interfaces.
#include "CPP/Common/Common.h"
#include "CPP/Common/MyCom.h"
#include "CPP/Common/UTFConvert.h"
#include "CPP/Windows/PropVariant.h"
#include "CPP/Windows/TimeUtils.h"
#include "CPP/7zip/Archive/IArchive.h"
#include "CPP/7zip/IPassword.h"
#include "C/7zVersion.h"
#include "SevenZipBridge.h"
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cctype>
#include <cstring>
#include <cstdio>
#include <fcntl.h>
#include <mutex>
#include <map>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>

STDAPI CreateObject(const GUID *, const GUID *, void **);
STDAPI GetNumberOfFormats(UInt32 *);
STDAPI GetHandlerProperty2(UInt32, PROPID, PROPVARIANT *);
using NWindows::NCOM::CPropVariant;

namespace {
struct Failure: std::runtime_error { using std::runtime_error::runtime_error; };
struct Context {
  SZBCallbacks cb{};
  std::atomic<uint64_t> total{0};
  std::atomic<bool> error{false}, warning{false};
  std::recursive_mutex messages;
  explicit Context(const SZBCallbacks *c) { if(c) cb=*c; }
  bool cancelled() const { return cb.is_cancelled && cb.is_cancelled(cb.context); }
  HRESULT check() const { return cancelled() ? E_ABORT : S_OK; }
  void message(int severity,const std::string &s) {
    std::lock_guard<std::recursive_mutex> lock(messages);
    if(severity==2) error=true;
    if(severity==1) warning=true;
    if(cb.message) cb.message(cb.context,severity,s.c_str());
  }
  HRESULT progress(uint64_t done) {
    if(cb.progress) cb.progress(cb.context,done,total.load());
    return check();
  }
  int result(HRESULT hr) {
    if(cancelled()) return SZB_CANCELLED;
    if(hr!=S_OK || error) {
      if(!error) message(2,"Archive operation failed (code " + std::to_string((uint32_t)hr) + ").");
      return SZB_ERROR;
    }
    return warning ? SZB_WARNING : SZB_OK;
  }
};
static UString unicode(const char *s) {
  UString out;
  if(!s || !ConvertUTF8ToUnicode(AString(s),out)) throw Failure("Invalid UTF-8 string.");
  return out;
}
static std::string utf8(const UString &s) { AString out; ConvertUnicodeToUTF8(s,out); return out.Ptr(); }
static CPropVariant prop(IInArchive *archive, UInt32 i, PROPID id) {
  CPropVariant p;
  if(archive->GetProperty(i,id,&p)!=S_OK) throw Failure("Cannot read archive item properties.");
  return p;
}
static bool boolean(IInArchive *archive,UInt32 i,PROPID id) { auto p=prop(archive,i,id); return p.vt==VT_BOOL && p.boolVal!=0; }
static std::string itemPath(IInArchive *archive,UInt32 i,const std::string &fallback) {
  auto p=prop(archive,i,kpidPath);
  if(p.vt==VT_BSTR && p.bstrVal && p.bstrVal[0]) return utf8(UString(p.bstrVal));
  return fallback;
}
static bool safePath(const std::string &s) {
  if(s.empty() || s[0]=='/' || s.find('\0')!=std::string::npos) return false;
  size_t pos=0;
  while(pos<s.size()) {
    auto end=s.find('/',pos); if(end==std::string::npos) end=s.size();
    auto part=s.substr(pos,end-pos);
    if(part.empty() || part=="." || part=="..") return false;
    if(pos==0 && part.size()>=2 && part[1]==':') return false;
    pos=end+1;
  }
  return true;
}
static std::string normalized(std::string s) {
  std::replace(s.begin(),s.end(),'\\','/');
  while(s.compare(0,2,"./")==0) s.erase(0,2);
  while(!s.empty() && s.back()=='/') s.pop_back();
  if(s==".") s.clear();
  return s;
}
static HRESULT ioError(Context *ctx,const char *what) {
  ctx->message(2,std::string(what)+": "+strerror(errno)); return E_FAIL;
}

class Input final: public IInStream, public CMyUnknownImp {
  Z7_IFACES_IMP_UNK_1(IInStream)
  Z7_IFACE_COM7_IMP(ISequentialInStream)
public:
  int fd; Context *ctx;
  Input(int file,Context *c):fd(file),ctx(c) {}
  ~Input(){ if(fd>=0) close(fd); }
};
Z7_COM7F_IMF(Input::Read(void *data,UInt32 size,UInt32 *processed)) {
  if(processed) *processed=0;
  if(ctx->check()!=S_OK) return E_ABORT;
  ssize_t n; do { n=read(fd,data,size); } while(n<0 && errno==EINTR);
  if(n<0) return ioError(ctx,"Cannot read input");
  if(processed) *processed=(UInt32)n;
  return S_OK;
}
Z7_COM7F_IMF(Input::Seek(Int64 offset,UInt32 origin,UInt64 *position)) {
  if(origin>2) return E_INVALIDARG;
  off_t n=lseek(fd,offset,(int)origin);
  if(n<0) return E_FAIL;
  if(position) *position=(UInt64)n;
  return ctx->check();
}
class Output final: public IOutStream, public CMyUnknownImp {
  Z7_IFACES_IMP_UNK_1(IOutStream)
  Z7_IFACE_COM7_IMP(ISequentialOutStream)
public:
  int fd; Context *ctx;
  Output(int file,Context *c):fd(file),ctx(c) {}
  ~Output(){ if(fd>=0) close(fd); }
};
Z7_COM7F_IMF(Output::Write(const void *data,UInt32 size,UInt32 *processed)) {
  if(processed) *processed=0;
  if(ctx->check()!=S_OK) return E_ABORT;
  ssize_t n; do { n=write(fd,data,size); } while(n<0 && errno==EINTR);
  if(n<0) return ioError(ctx,"Cannot write output");
  if(processed) *processed=(UInt32)n;
  return S_OK;
}
Z7_COM7F_IMF(Output::Seek(Int64 offset,UInt32 origin,UInt64 *position)) {
  if(origin>2) return E_INVALIDARG;
  off_t n=lseek(fd,offset,(int)origin);
  if(n<0) return E_FAIL;
  if(position) *position=(UInt64)n;
  return ctx->check();
}
Z7_COM7F_IMF(Output::SetSize(UInt64 size)) { return size>INT64_MAX || ftruncate(fd,(off_t)size)!=0 ? E_FAIL : ctx->check(); }

class OpenCallback final: public IArchiveOpenCallback,public ICryptoGetTextPassword,public IArchiveOpenVolumeCallback,public CMyUnknownImp {
  Z7_IFACES_IMP_UNK_3(IArchiveOpenCallback,ICryptoGetTextPassword,IArchiveOpenVolumeCallback)
public:
  Context *ctx; const char *password; bool requested=false, volumeOpened=false; std::string archivePath;
  int metadataFD=-1; std::string memberName;
  OpenCallback(Context *c,const char *p,const char *path):ctx(c),password(p),archivePath(path) {}
};
Z7_COM7F_IMF(OpenCallback::SetTotal(const UInt64 *,const UInt64 *)) { return ctx->check(); }
Z7_COM7F_IMF(OpenCallback::SetCompleted(const UInt64 *,const UInt64 *)) { return ctx->check(); }
Z7_COM7F_IMF(OpenCallback::CryptoGetTextPassword(BSTR *p)) {
  requested=true;
  if(!password || !*password) return E_ABORT;
  return StringToBstr(unicode(password),p);
}
Z7_COM7F_IMF(OpenCallback::GetProperty(PROPID key,PROPVARIANT *value)) {
  CPropVariant p;
  struct stat st{};
  if((metadataFD>=0?fstat(metadataFD,&st):stat(archivePath.c_str(),&st))!=0)return E_FAIL;
  switch(key){
    case kpidName:{auto pos=archivePath.find_last_of('/');p=unicode((memberName.empty()?archivePath.substr(pos==std::string::npos?0:pos+1):memberName).c_str());break;}
    case kpidSize:p=(UInt64)st.st_size;break;
    case kpidIsDir:p=false;break;
    case kpidMTime:{FILETIME ft;FiTime_To_FILETIME(st.st_mtimespec,ft);p=ft;break;}
  }
  p.Detach(value);return ctx->check();
}
Z7_COM7F_IMF(OpenCallback::GetStream(const wchar_t *volume,IInStream **stream)) {
  *stream=nullptr;
  if(ctx->check()!=S_OK)return E_ABORT;
  if(metadataFD>=0)return S_FALSE; // A decoded TAR has no adjacent volumes.
  const std::string name=utf8(UString(volume));
  // Archive-provided volume names are adjacent leaf names, never arbitrary paths.
  if(!safePath(name) || name.find('/')!=std::string::npos || name.find('\\')!=std::string::npos)return S_FALSE;
  auto pos=archivePath.find_last_of('/');
  std::string full=(pos==std::string::npos?std::string():archivePath.substr(0,pos+1))+name;
  int fd=open(full.c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
  if(fd<0)return S_FALSE;
  volumeOpened=true;
  CMyComPtr<IInStream> holder=new Input(fd,ctx);*stream=holder.Detach();return S_OK;
}
struct Opened {
  CMyComPtr<IInStream> input;
  CMyComPtr<IInArchive> archive;
  std::string fallback;
  GUID classID{};
  bool headerEncrypted=false, volumeOpened=false;
  ~Opened(){ if(archive) archive->Close(); }
};
// Compressed TAR is one logical archive. Decode only explicitly named TAR
// wrappers, so plain .gz files and archives stored inside ZIP/7z stay unchanged.
static bool compressedTarName(std::string name) {
  std::transform(name.begin(),name.end(),name.begin(),[](unsigned char c){return (char)tolower(c);});
  for(const char *suffix:{".tar.gz",".tgz",".tar.bz2",".tbz",".tbz2",".tar.xz",".txz",
                          ".tar.lzma",".tar.zst",".tar.zstd",".tzst"}) {
    const size_t length=strlen(suffix);
    if(name.size()>=length && name.compare(name.size()-length,length,suffix)==0)return true;
  }
  return false;
}
static std::string formatName(UInt32 index) {
  CPropVariant p; GetHandlerProperty2(index,NArchive::NHandlerPropID::kName,&p);
  std::string name=p.vt==VT_BSTR?utf8(UString(p.bstrVal)):"";
  std::transform(name.begin(),name.end(),name.begin(),[](unsigned char c){return (char)tolower(c);});
  return name;
}
static void reportHeaderWarnings(IInArchive *archive,Context &ctx) {
  for(auto key:{kpidErrorFlags,kpidWarningFlags}) {
    CPropVariant flags;
    if(archive->GetArchiveProperty(key,&flags)==S_OK && flags.vt==VT_UI4 && flags.ulVal)
      ctx.message(1,"The archive reports header warnings (flags "+std::to_string(flags.ulVal)+").");
  }
}
class TarEnvelopeCallback final: public IArchiveExtractCallback,public CMyUnknownImp {
  Z7_IFACES_IMP_UNK_1(IArchiveExtractCallback)
  Z7_IFACE_COM7_IMP(IProgress)
public:
  Context *ctx; CMyComPtr<ISequentialOutStream> output; bool completed=false;
  TarEnvelopeCallback(Context *c,ISequentialOutStream *stream):ctx(c),output(stream) {}
};
Z7_COM7F_IMF(TarEnvelopeCallback::SetTotal(UInt64 size)) {ctx->total=size;return ctx->progress(0);}
Z7_COM7F_IMF(TarEnvelopeCallback::SetCompleted(const UInt64 *size)) {return ctx->progress(size?*size:0);}
Z7_COM7F_IMF(TarEnvelopeCallback::GetStream(UInt32 index,ISequentialOutStream **stream,Int32 mode)) {
  *stream=nullptr;
  if(ctx->check()!=S_OK)return E_ABORT;
  if(index!=0 || mode!=NArchive::NExtract::NAskMode::kExtract)return E_INVALIDARG;
  *stream=output;(*stream)->AddRef();return S_OK;
}
Z7_COM7F_IMF(TarEnvelopeCallback::PrepareOperation(Int32)) {return ctx->check();}
Z7_COM7F_IMF(TarEnvelopeCallback::SetOperationResult(Int32 result)) {
  completed=result==NArchive::NExtract::NOperationResult::kOK;
  if(!completed)ctx->message(2,"Cannot decode compressed TAR (code "+std::to_string(result)+"). The data or checksum is damaged.");
  return ctx->check();
}
static HRESULT openCompressedTar(const char *path,const char *password,UInt32 format,Context &ctx,Opened &opened) {
  if(!compressedTarName(path))return S_OK;
  const std::string kind=formatName(format);
  if(kind!="gzip" && kind!="bzip2" && kind!="xz" && kind!="lzma" && kind!="zstd" && kind!="zstd2")return S_OK;
  UInt32 count=0;HRESULT hr=opened.archive->GetNumberOfItems(&count);
  if(hr!=S_OK)return hr;
  if(count!=1 || boolean(opened.archive,0,kpidIsDir))throw Failure("Compressed TAR must contain one data stream.");

  // tmpfile is private and unlinked; the duplicated descriptor outlives FILE.
  // All paths supplied by compression headers are ignored, and every exit
  // closes the descriptors through COM ownership (including cancellation).
  FILE *temporary=std::tmpfile();
  if(!temporary)return ioError(&ctx,"Cannot create temporary TAR storage");
  int fd=fcntl(fileno(temporary),F_DUPFD_CLOEXEC,0);
  const int savedError=errno;fclose(temporary);errno=savedError;
  if(fd<0)return ioError(&ctx,"Cannot access temporary TAR storage");
  CMyComPtr<IInStream> input=new Input(fd,&ctx);
  int writeFD=fcntl(fd,F_DUPFD_CLOEXEC,0);
  if(writeFD<0)return ioError(&ctx,"Cannot write temporary TAR storage");
  CMyComPtr<ISequentialOutStream> output=new Output(writeFD,&ctx);
  auto *decoder=new TarEnvelopeCallback(&ctx,output);
  CMyComPtr<IArchiveExtractCallback> decoderHolder=decoder;
  hr=opened.archive->Extract(nullptr,(UInt32)-1,0,decoder);
  if(hr!=S_OK)return hr;
  if(ctx.check()!=S_OK)return E_ABORT;
  if(!decoder->completed || ctx.error)return E_FAIL;
  decoder->output.Release();output.Release();
  hr=input->Seek(0,STREAM_SEEK_SET,nullptr);if(hr!=S_OK)return hr;

  UInt32 formats=0;GetNumberOfFormats(&formats);
  for(UInt32 index=0;index<formats;index++) {
    if(formatName(index)!="tar")continue;
    CPropVariant classProp;GetHandlerProperty2(index,NArchive::NHandlerPropID::kClassID,&classProp);
    if(classProp.vt!=VT_BSTR || SysStringByteLen(classProp.bstrVal)!=sizeof(GUID))return E_FAIL;
    GUID cls;memcpy(&cls,classProp.bstrVal,sizeof(cls));
    CMyComPtr<IInArchive> tar;
    hr=CreateObject(&cls,&IID_IInArchive,(void**)&tar);if(hr!=S_OK)return hr;
    auto *callback=new OpenCallback(&ctx,password,path);
    callback->metadataFD=fd;callback->memberName="Content.tar"; // Recognizes empty TARs too.
    CMyComPtr<IArchiveOpenCallback> holder=callback;
    UInt64 maxCheck=1<<23;
    hr=tar->Open(input,&maxCheck,callback);
    if(hr!=S_OK) {
      tar->Close();
      if(hr!=E_ABORT)ctx.message(2,"The compressed stream is not a valid TAR archive.");
      return hr;
    }
    opened.archive->Close();
    opened.archive=tar;opened.input=input;opened.classID=cls;opened.fallback="Content";
    reportHeaderWarnings(tar,ctx);
    return S_OK;
  }
  throw Failure("The TAR decoder is unavailable.");
}
static HRESULT openArchive(const char *path,const char *password,Context &ctx,Opened &opened) {
  if(!path || !*path) throw Failure("Archive path is empty.");
  int fd=open(path,O_RDONLY|O_CLOEXEC);
  if(fd<0) return ioError(&ctx,"Cannot open archive");
  opened.input=new Input(fd,&ctx);
  std::string name=path;
  name=name.substr(name.find_last_of('/')==std::string::npos ? 0 : name.find_last_of('/')+1);
  auto dot=name.find_last_of('.');
  auto ext=dot==std::string::npos ? "" : name.substr(dot+1);
  std::transform(ext.begin(),ext.end(),ext.begin(),[](unsigned char c){return (char)tolower(c);});
  opened.fallback=dot==std::string::npos?name:name.substr(0,dot);
  if(opened.fallback.empty()) opened.fallback="Content";
  UInt32 formats=0; GetNumberOfFormats(&formats);
  std::vector<UInt32> ordered;
  for(UInt32 i=0;i<formats;i++) {
    CPropVariant p; GetHandlerProperty2(i,NArchive::NHandlerPropID::kExtension,&p);
    std::string extensions=p.vt==VT_BSTR ? " "+utf8(UString(p.bstrVal))+" " : "";
    if(!ext.empty() && extensions.find(" "+ext+" ")!=std::string::npos) ordered.insert(ordered.begin(),i);
    else ordered.push_back(i);
  }
  bool passwordRequested=false;
  for(auto index:ordered) {
    if(ctx.cancelled()) return E_ABORT;
    CPropVariant classProp; GetHandlerProperty2(index,NArchive::NHandlerPropID::kClassID,&classProp);
    if(classProp.vt!=VT_BSTR || SysStringByteLen(classProp.bstrVal)!=sizeof(GUID)) continue;
    GUID cls; memcpy(&cls,classProp.bstrVal,sizeof(cls));
    CMyComPtr<IInArchive> arc;
    if(CreateObject(&cls,&IID_IInArchive,(void**)&arc)!=S_OK) continue;
    opened.input->Seek(0,STREAM_SEEK_SET,nullptr);
    auto *callback=new OpenCallback(&ctx,password,path);
    CMyComPtr<IArchiveOpenCallback> holder=callback;
    UInt64 maxCheck=1<<23;
    HRESULT hr=arc->Open(opened.input,&maxCheck,callback);
    passwordRequested |= callback->requested;
    if(hr==S_OK){
      opened.archive=arc;
      opened.classID=cls;opened.headerEncrypted=callback->requested;opened.volumeOpened=callback->volumeOpened;
      reportHeaderWarnings(arc,ctx);
      return openCompressedTar(path,password,index,ctx,opened);
    }
    arc->Close();
    if(callback->requested) break;
  }
  ctx.message(2,passwordRequested ? "Cannot open encrypted archive. A correct password is required." : "Cannot open this archive: unsupported format or damaged header.");
  return S_FALSE;
}
static SZBEntry readEntry(IInArchive *arc,UInt32 i,std::string &name,const std::string &fallback) {
  SZBEntry e{}; name=normalized(itemPath(arc,i,fallback)); e.path=name.c_str();
  if(boolean(arc,i,kpidIsDir)) e.flags|=SZB_ENTRY_DIRECTORY;
  if(boolean(arc,i,kpidEncrypted)) e.flags|=SZB_ENTRY_ENCRYPTED;
  auto size=prop(arc,i,kpidSize);
  if(size.vt==VT_UI8){e.size=size.uhVal.QuadPart; e.flags|=SZB_ENTRY_HAS_SIZE;}
  else if(size.vt==VT_UI4){e.size=size.ulVal;e.flags|=SZB_ENTRY_HAS_SIZE;}
  auto packed=prop(arc,i,kpidPackSize);
  if(packed.vt==VT_UI8){e.packed_size=packed.uhVal.QuadPart;e.flags|=SZB_ENTRY_HAS_PACKED_SIZE;}
  auto date=prop(arc,i,kpidMTime);
  if(date.vt==VT_FILETIME){ timespec ts{}; if(FILETIME_To_timespec(date.filetime,ts)){e.modified_seconds=ts.tv_sec;e.flags|=SZB_ENTRY_HAS_MODIFIED;} }
  return e;
}
static bool linkedItem(IInArchive *arc,UInt32 i) {
  for(auto key:{kpidSymLink,kpidHardLink}) {auto p=prop(arc,i,key);if(p.vt==VT_BSTR && p.bstrVal && p.bstrVal[0])return true;}
  auto attr=prop(arc,i,kpidPosixAttrib);
  if(attr.vt==VT_UI4 && (attr.ulVal&S_IFMT)==S_IFLNK)return true;
  auto winAttr=prop(arc,i,kpidAttrib);
  return winAttr.vt==VT_UI4 && ((winAttr.ulVal>>16)&S_IFMT)==S_IFLNK;
}
static int directoryAt(int parent,const std::string &name) {
  if(mkdirat(parent,name.c_str(),0755)!=0 && errno!=EEXIST) return -1;
  return openat(parent,name.c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
}
static int openParent(int root,const std::string &path,std::string &leaf) {
  int current=dup(root);
  if(current<0)return -1;
  size_t start=0;
  for(;;) {
    size_t end=path.find('/',start);
    if(end==std::string::npos){leaf=path.substr(start);return current;}
    auto part=path.substr(start,end-start);
    int next=directoryAt(current,part);close(current);
    if(next<0)return -1;
    current=next;start=end+1;
  }
}
class ExtractCallback final: public IArchiveExtractCallback,public ICryptoGetTextPassword,public CMyUnknownImp {
  Z7_IFACES_IMP_UNK_2(IArchiveExtractCallback,ICryptoGetTextPassword)
  Z7_IFACE_COM7_IMP(IProgress)
public:
  Context *ctx; IInArchive *archive; const char *password; int root;
  std::string fallback,name,leaf; int parent=-1;
  Output *output=nullptr; CMyComPtr<ISequentialOutStream> stream;
  UInt32 index=0;
  ExtractCallback(Context *c,IInArchive *a,const char *p,int r,const std::string &f):ctx(c),archive(a),password(p),root(r),fallback(f){}
  ~ExtractCallback(){ cleanup(true); if(root>=0)close(root); }
  void cleanup(bool remove) {
    stream.Release();output=nullptr;
    if(parent>=0){if(remove && !leaf.empty())unlinkat(parent,leaf.c_str(),0);close(parent);parent=-1;}
    leaf.clear();
  }
};
Z7_COM7F_IMF(ExtractCallback::SetTotal(UInt64 n)){ctx->total=n;return ctx->progress(0);}
Z7_COM7F_IMF(ExtractCallback::SetCompleted(const UInt64 *n)){return ctx->progress(n?*n:0);}
Z7_COM7F_IMF(ExtractCallback::CryptoGetTextPassword(BSTR *p)){
  if(!password || !*password){ctx->message(2,"This archive requires a password.");return E_ABORT;}
  return StringToBstr(unicode(password),p);
}
Z7_COM7F_IMF(ExtractCallback::GetStream(UInt32 item,ISequentialOutStream **out,Int32 ask)) {
  *out=nullptr;cleanup(true);index=item;
  if(ctx->check()!=S_OK)return E_ABORT;
  name=normalized(itemPath(archive,item,fallback));
  if(ask!=NArchive::NExtract::NAskMode::kExtract)return S_OK;
  if(name.empty() && boolean(archive,item,kpidIsDir))return S_OK;
  if(!safePath(name)){ctx->message(2,"Invalid entry path: "+name);return E_FAIL;}
  if(linkedItem(archive,item)){ctx->message(2,"Symbolic and hard links are not supported: "+name);return E_FAIL;}
  std::string originalLeaf;
  int dir=openParent(root,name,originalLeaf);
  if(dir<0)return ioError(ctx,"Cannot create output directory");
  if(boolean(archive,item,kpidIsDir)){
    int child=directoryAt(dir,originalLeaf);close(dir);
    if(child<0)return ioError(ctx,"Cannot create output directory");
    close(child);return S_OK;
  }
  int fd=-1;
  std::string chosen=originalLeaf;
  for(unsigned suffix=0;suffix<100000;suffix++) {
    if(suffix) {
      auto dot=originalLeaf.find_last_of('.');
      if(dot==std::string::npos || dot==0)chosen=originalLeaf+"_"+std::to_string(suffix);
      else chosen=originalLeaf.substr(0,dot)+"_"+std::to_string(suffix)+originalLeaf.substr(dot);
    }
    fd=openat(dir,chosen.c_str(),O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd>=0 || errno!=EEXIST)break;
  }
  if(fd<0){close(dir);return ioError(ctx,"Cannot create output file");}
  parent=dir;leaf=chosen;output=new Output(fd,ctx);stream=output;
  *out=stream;(*out)->AddRef();return S_OK;
}
Z7_COM7F_IMF(ExtractCallback::PrepareOperation(Int32 ask)) {
  if(ask==NArchive::NExtract::NAskMode::kExtract || ask==NArchive::NExtract::NAskMode::kTest)ctx->message(0,name);
  return ctx->check();
}
Z7_COM7F_IMF(ExtractCallback::SetOperationResult(Int32 result)) {
  if(result!=NArchive::NExtract::NOperationResult::kOK) {
    ctx->message(2,"Cannot decode entry: "+name+" (code "+std::to_string(result)+"). Check the data and password.");
    cleanup(true);return S_OK;
  }
  if(output){
    auto attr=prop(archive,index,kpidPosixAttrib);
    mode_t mode=0644;
    if(attr.vt==VT_UI4)mode=attr.ulVal&0777;
    fchmod(output->fd,mode);
    auto date=prop(archive,index,kpidMTime);
    if(date.vt==VT_FILETIME){timespec times[2]{};if(FILETIME_To_timespec(date.filetime,times[1])){times[0]=times[1];futimens(output->fd,times);}}
  }
  cleanup(false);return ctx->check();
}
struct Source {std::string disk,path; struct stat st{}; UInt32 oldIndex=UINT32_MAX;};
class UpdateCallback final: public IArchiveUpdateCallback,public ICryptoGetTextPassword2,public ICryptoGetTextPassword,public CMyUnknownImp {
  Z7_IFACES_IMP_UNK_3(IArchiveUpdateCallback,ICryptoGetTextPassword2,ICryptoGetTextPassword)
  Z7_IFACE_COM7_IMP(IProgress)
public:
  Context *ctx; const char *password; std::vector<Source> sources;
  IInArchive *original=nullptr;
  UpdateCallback(Context *c,const char *p):ctx(c),password(p){}
};
Z7_COM7F_IMF(UpdateCallback::SetTotal(UInt64 n)){ctx->total=n;return ctx->progress(0);}
Z7_COM7F_IMF(UpdateCallback::SetCompleted(const UInt64 *n)){return ctx->progress(n?*n:0);}
Z7_COM7F_IMF(UpdateCallback::GetUpdateItemInfo(UInt32 i,Int32 *data,Int32 *properties,UInt32 *old)) {
  if(i>=sources.size())return E_INVALIDARG;
  const UInt32 oldIndex=sources[i].oldIndex;
  if(data)*data=oldIndex==UINT32_MAX;if(properties)*properties=oldIndex==UINT32_MAX;
  if(old)*old=oldIndex;return ctx->check();
}
Z7_COM7F_IMF(UpdateCallback::GetProperty(UInt32 i,PROPID key,PROPVARIANT *value)) {
  if(i>=sources.size())return E_INVALIDARG;
  const auto &source=sources[i];CPropVariant p;
  if(source.oldIndex!=UINT32_MAX)return original?original->GetProperty(source.oldIndex,key,value):E_INVALIDARG;
  switch(key){
    case kpidPath:p=unicode(source.path.c_str());break;
    case kpidIsDir:p=(bool)S_ISDIR(source.st.st_mode);break;
    case kpidSize:p=(UInt64)(S_ISDIR(source.st.st_mode)?0:source.st.st_size);break;
    case kpidPosixAttrib:p=(UInt32)source.st.st_mode;break;
    case kpidAttrib:p=(UInt32)((source.st.st_mode<<16)|0x8000|(S_ISDIR(source.st.st_mode)?FILE_ATTRIBUTE_DIRECTORY:FILE_ATTRIBUTE_ARCHIVE));break;
    case kpidMTime:{FILETIME ft;FiTime_To_FILETIME(source.st.st_mtimespec,ft);p=ft;break;}
    case kpidIsAnti:p=false;break;
  }
  p.Detach(value);return ctx->check();
}
Z7_COM7F_IMF(UpdateCallback::GetStream(UInt32 i,ISequentialInStream **in)) {
  *in=nullptr;if(i>=sources.size())return E_INVALIDARG;
  if(ctx->check()!=S_OK)return E_ABORT;
  const auto &source=sources[i];ctx->message(0,source.path);
  if(source.oldIndex!=UINT32_MAX)return E_INVALIDARG;
  if(S_ISDIR(source.st.st_mode))return S_OK;
  int fd=open(source.disk.c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
  if(fd<0)return ioError(ctx,"Cannot open source file");
  struct stat current{};
  if(fstat(fd,&current)!=0 || !S_ISREG(current.st_mode) || current.st_dev!=source.st.st_dev ||
     current.st_ino!=source.st.st_ino || current.st_size!=source.st.st_size ||
     current.st_mtimespec.tv_sec!=source.st.st_mtimespec.tv_sec || current.st_mtimespec.tv_nsec!=source.st.st_mtimespec.tv_nsec) {
    close(fd);ctx->message(2,"The source file changed during compression: "+source.path);return E_FAIL;
  }
  CMyComPtr<ISequentialInStream> holder=new Input(fd,ctx);*in=holder.Detach();return S_OK;
}
Z7_COM7F_IMF(UpdateCallback::SetOperationResult(Int32 result)){
  if(result!=NArchive::NUpdate::NOperationResult::kOK)ctx->message(2,"Cannot encode input file.");return ctx->check();
}
Z7_COM7F_IMF(UpdateCallback::CryptoGetTextPassword2(Int32 *defined,BSTR *p)){
  *defined=password && *password;
  return StringToBstr(unicode(password?password:""),p);
}
Z7_COM7F_IMF(UpdateCallback::CryptoGetTextPassword(BSTR *p)){
  if(!password || !*password){ctx->message(2,"This archive requires its original password.");return E_ABORT;}
  return StringToBstr(unicode(password),p);
}
static GUID archiveClass(int format) {
  GUID g={0x23170f69,0x40c1,0x278a,{0x10,0,0,1,0x10,(Byte)format,0,0}};return g;
}
template<typename F> int guarded(const SZBCallbacks *callbacks,F work) {
  Context ctx(callbacks);
  try {if(ctx.cancelled())return SZB_CANCELLED;return ctx.result(work(ctx));}
  catch(const std::exception &e){ctx.message(2,e.what());return ctx.cancelled()?SZB_CANCELLED:SZB_ERROR;}
  catch(...){ctx.message(2,"Unexpected archive engine failure.");return ctx.cancelled()?SZB_CANCELLED:SZB_ERROR;}
}
static HRESULT extract(const char *path,const char *destination,const char *const *selected,size_t count,const char *password,bool test,Context &ctx) {
  Opened opened;HRESULT hr=openArchive(path,password,ctx,opened);if(hr!=S_OK)return hr;
  std::vector<UInt32> indices;
  UInt32 n=0;opened.archive->GetNumberOfItems(&n);
  if(selected){
    if(count==0)throw Failure("Empty extraction selection.");
    for(UInt32 i=0;i<n;i++){
      auto name=normalized(itemPath(opened.archive,i,opened.fallback));
      for(size_t j=0;j<count;j++){
        if(!selected[j])throw Failure("Invalid selection.");
        auto prefix=normalized(selected[j]);
        if(name==prefix || (name.size()>prefix.size() && name.compare(0,prefix.size(),prefix)==0 && name[prefix.size()]=='/')){indices.push_back(i);break;}
      }
    }
    if(indices.empty())throw Failure("No selected entries were found.");
  }
  int root=-1;
  if(!test){
    if(!destination || !*destination)throw Failure("Output directory is empty.");
    // The Swift layer creates the chosen root. It is the trusted output boundary.
    if(mkdir(destination,0755)!=0 && errno!=EEXIST)return ioError(&ctx,"Cannot create output directory");
    root=open(destination,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(root<0)return ioError(&ctx,"Cannot open output directory");
  }
  auto *callback=new ExtractCallback(&ctx,opened.archive,password,root,opened.fallback);
  CMyComPtr<IArchiveExtractCallback> holder=callback;
  return opened.archive->Extract(selected?indices.data():nullptr,selected?(UInt32)indices.size():(UInt32)-1,test?1:0,callback);
}
}
extern "C" const char *szb_version(void){return MY_VERSION;}
extern "C" int szb_list(const char *path,const char *password,const SZBCallbacks *cb){
  return guarded(cb,[&](Context &ctx)->HRESULT{
    Opened opened;HRESULT hr=openArchive(path,password,ctx,opened);if(hr!=S_OK)return hr;
    UInt32 count=0;hr=opened.archive->GetNumberOfItems(&count);if(hr!=S_OK)return hr;
    ctx.total=count;
    for(UInt32 i=0;i<count;i++){
      if(ctx.check()!=S_OK)return E_ABORT;
      std::string name;auto entry=readEntry(opened.archive,i,name,opened.fallback);
      if(!name.empty() && ctx.cb.entry)ctx.cb.entry(ctx.cb.context,&entry);
      if(ctx.progress(i+1)!=S_OK)return E_ABORT;
    }return S_OK;
  });
}
extern "C" int szb_create(const char *path,int format,int level,const char *password,const char *const *sources,const char *const *paths,size_t count,const SZBCallbacks *cb){
  return guarded(cb,[&](Context &ctx)->HRESULT{
    if(!path || !sources || !paths || !count || count>UINT32_MAX || level<0 || level>9 || (format!=SZB_FORMAT_7Z && format!=SZB_FORMAT_ZIP))throw Failure("Invalid creation arguments.");
    auto *callback=new UpdateCallback(&ctx,password);CMyComPtr<IArchiveUpdateCallback> holder=callback;
    std::set<std::string> names;
    for(size_t i=0;i<count;i++){
      if(ctx.check()!=S_OK)return E_ABORT;
      if(!sources[i] || !paths[i] || !safePath(paths[i]) || !names.insert(paths[i]).second)throw Failure("Invalid or duplicate input path.");
      Source s;s.disk=sources[i];s.path=paths[i];
      if(lstat(s.disk.c_str(),&s.st)!=0)return ioError(&ctx,"Cannot inspect input file");
      if(!S_ISREG(s.st.st_mode) && !S_ISDIR(s.st.st_mode))throw Failure("Only regular files and directories can be compressed.");
      callback->sources.push_back(s);
    }
    GUID cls=archiveClass(format);CMyComPtr<IOutArchive> archive;
    HRESULT hr=CreateObject(&cls,&IID_IOutArchive,(void**)&archive);if(hr!=S_OK)return hr;
    CMyComPtr<ISetProperties> properties;archive.QueryInterface(IID_ISetProperties,&properties);
    if(properties){
      const wchar_t *keys[3]={L"x",nullptr,nullptr};CPropVariant values[3];values[0]=(UInt32)level;UInt32 n=1;
      if(password && *password){keys[n]=format==SZB_FORMAT_7Z?L"he":L"em";if(format==SZB_FORMAT_7Z)values[n]=true;else values[n]=L"AES256";n++;}
      hr=properties->SetProperties(keys,values,n);if(hr!=S_OK)return hr;
    }
    int fd=open(path,O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return ioError(&ctx,"Cannot create archive");
    CMyComPtr<IOutStream> output=new Output(fd,&ctx);
    ctx.message(0,"Creating archive");
    hr=archive->UpdateItems(output,(UInt32)count,callback);
    output.Release();
    if(hr!=S_OK || ctx.error || ctx.cancelled())unlink(path);
    return hr;
  });
}
extern "C" int szb_update(const char *path,const char *outputPath,int format,const char *password,
                           const char *const *sources,const char *const *paths,size_t count,
                           const char *const *deleted,size_t deletedCount,const SZBCallbacks *cb){
  return guarded(cb,[&](Context &ctx)->HRESULT{
    if(!path || !outputPath || !*outputPath || (count && (!sources || !paths)) ||
       (deletedCount && !deleted) || (!count && !deletedCount) || count>UINT32_MAX ||
       deletedCount>UINT32_MAX || (format!=SZB_FORMAT_7Z && format!=SZB_FORMAT_ZIP))
      throw Failure("Invalid update arguments.");
    struct stat originalStat{};
    if(lstat(path,&originalStat)!=0)return ioError(&ctx,"Cannot inspect archive");
    if(!S_ISREG(originalStat.st_mode))throw Failure("Only regular archive files can be updated.");
    Opened opened;HRESULT hr=openArchive(path,password,ctx,opened);if(hr!=S_OK)return hr;
    const GUID expected=archiveClass(format);
    if(memcmp(&expected,&opened.classID,sizeof(GUID))!=0)
      throw Failure("The actual archive format does not match the selected ZIP or 7z format.");
    if(ctx.warning || opened.volumeOpened)throw Failure("Archives with header warnings or multiple volumes cannot be updated.");
    for(auto key:{kpidReadOnly,kpidIsVolume,kpidOffset,kpidEmbeddedStubSize}){
      CPropVariant p;hr=opened.archive->GetArchiveProperty(key,&p);if(hr!=S_OK)return hr;
      if((p.vt==VT_BOOL && p.boolVal) || (p.vt==VT_UI8 && p.uhVal.QuadPart) || (p.vt==VT_UI4 && p.ulVal))
        throw Failure("Read-only, embedded and multi-volume archives cannot be updated.");
    }
    CMyComPtr<IOutArchive> archive;
    hr=opened.archive.QueryInterface(IID_IOutArchive,&archive);
    if(hr!=S_OK || !archive)throw Failure("This archive does not support updating.");

    std::vector<std::string> removals;
    std::vector<bool> removalFound(deletedCount,false);
    for(size_t i=0;i<deletedCount;i++){
      if(!deleted[i])throw Failure("Invalid deletion path.");
      const auto name=normalized(deleted[i]);
      if(!safePath(name))throw Failure("Invalid deletion path: "+name);
      removals.push_back(name);
    }
    auto contains=[](const std::string &parent,const std::string &child){
      return child==parent || (child.size()>parent.size() && child.compare(0,parent.size(),parent)==0 && child[parent.size()]=='/');
    };
    std::map<std::string,Source> additions;
    for(size_t i=0;i<count;i++){
      if(ctx.check()!=S_OK)return E_ABORT;
      if(!sources[i] || !paths[i] || !safePath(paths[i]) || normalized(paths[i])!=paths[i])
        throw Failure("Invalid input archive path.");
      Source s;s.disk=sources[i];s.path=paths[i];
      if(lstat(s.disk.c_str(),&s.st)!=0)return ioError(&ctx,"Cannot inspect input file");
      if(!S_ISREG(s.st.st_mode) && !S_ISDIR(s.st.st_mode))throw Failure("Only regular files and directories can be added.");
      if(s.st.st_dev==originalStat.st_dev && s.st.st_ino==originalStat.st_ino)
        throw Failure("An archive cannot be added to itself.");
      if(!additions.emplace(s.path,s).second)throw Failure("Duplicate input archive path: "+s.path);
    }
    auto *callback=new UpdateCallback(&ctx,password);CMyComPtr<IArchiveUpdateCallback> holder=callback;
    callback->original=opened.archive;
    UInt32 n=0;hr=opened.archive->GetNumberOfItems(&n);if(hr!=S_OK)return hr;
    if(count>UINT32_MAX-n)throw Failure("Too many archive entries.");
    std::set<std::string> originalNames;
    std::map<std::string,bool> finalNames;
    std::vector<UInt32> encryptedIndices;
    for(UInt32 i=0;i<n;i++){
      if(ctx.check()!=S_OK)return E_ABORT;
      const auto name=normalized(itemPath(opened.archive,i,opened.fallback));
      if(!safePath(name) || !originalNames.insert(name).second)
        throw Failure("Archives with unsafe or duplicate paths cannot be updated: "+name);
      const bool directory=boolean(opened.archive,i,kpidIsDir);
      if(boolean(opened.archive,i,kpidEncrypted))encryptedIndices.push_back(i);
      bool remove=false;
      for(size_t j=0;j<removals.size();j++)if(contains(removals[j],name)){remove=true;removalFound[j]=true;}
      if(remove)continue;
      auto replacement=additions.find(name);
      if(replacement!=additions.end()){
        if(directory!=(bool)S_ISDIR(replacement->second.st.st_mode))
          throw Failure("A file and directory have the same archive path: "+name);
        continue;
      }
      Source s;s.path=name;s.oldIndex=i;
      s.st.st_mode=directory?S_IFDIR:S_IFREG;
      callback->sources.push_back(s);finalNames.emplace(name,directory);
    }
    for(size_t i=0;i<removalFound.size();i++)if(!removalFound[i])throw Failure("The selected entry no longer exists: "+removals[i]);
    for(const auto &addition:additions){
      callback->sources.push_back(addition.second);
      finalNames.emplace(addition.first,S_ISDIR(addition.second.st.st_mode));
    }
    for(const auto &item:finalNames){
      size_t slash=item.first.find('/');
      while(slash!=std::string::npos){
        const auto parent=finalNames.find(item.first.substr(0,slash));
        if(parent!=finalNames.end() && !parent->second)
          throw Failure("An archive file blocks a parent directory: "+parent->first);
        slash=item.first.find('/',slash+1);
      }
    }
    const bool encrypted=opened.headerEncrypted || !encryptedIndices.empty();
    if(encrypted && (!password || !*password))throw Failure("This archive requires its original password before updating.");
    if(!encryptedIndices.empty()){
      // Copying encrypted bytes does not validate a password. Check every old
      // encrypted stream even when the requested edit removes all of them.
      ctx.message(0,"Verifying the archive password");
      auto *verify=new ExtractCallback(&ctx,opened.archive,password,-1,opened.fallback);
      CMyComPtr<IArchiveExtractCallback> verifyHolder=verify;
      hr=opened.archive->Extract(encryptedIndices.data(),(UInt32)encryptedIndices.size(),1,verify);
      if(hr!=S_OK || ctx.error || ctx.warning || ctx.cancelled())return hr==S_OK?E_FAIL:hr;
    }
    CMyComPtr<ISetProperties> properties;archive.QueryInterface(IID_ISetProperties,&properties);
    if(properties){
      // Let 7z preserve its existing header-encryption setting. For ZIP, new
      // encrypted entries use AES; untouched entries retain their original mode.
      const wchar_t *keys[2]={L"x",L"em"};CPropVariant values[2];values[0]=(UInt32)5;
      UInt32 numProperties=1;
      if(format==SZB_FORMAT_ZIP && password && *password){values[1]=L"AES256";numProperties=2;}
      hr=properties->SetProperties(keys,values,numProperties);if(hr!=S_OK)return hr;
    }
    int fd=open(outputPath,O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return ioError(&ctx,"Cannot create updated archive");
    struct OutputCleanup {
      const char *path;bool keep=false;
      ~OutputCleanup(){if(!keep)unlink(path);}
    } cleanup{outputPath};
    CMyComPtr<IOutStream> output=new Output(fd,&ctx);
    ctx.message(0,"Updating archive");
    hr=archive->UpdateItems(output,(UInt32)callback->sources.size(),callback);
    if(hr==S_OK && fsync(fd)!=0)hr=ioError(&ctx,"Cannot flush updated archive");
    output.Release();
    if(hr!=S_OK || ctx.error || ctx.warning || ctx.cancelled())return hr==S_OK?E_FAIL:hr;
    ctx.message(0,"Verifying updated archive");
    hr=extract(outputPath,nullptr,nullptr,0,password,true,ctx);
    if(hr!=S_OK || ctx.error || ctx.warning || ctx.cancelled())return hr==S_OK?E_FAIL:hr;
    cleanup.keep=true;
    return S_OK;
  });
}
extern "C" int szb_extract(const char *path,const char *destination,const char *const *selected,size_t count,const char *password,const SZBCallbacks *cb){
  return guarded(cb,[&](Context &ctx){return extract(path,destination,selected,count,password,false,ctx);});
}
extern "C" int szb_test(const char *path,const char *password,const SZBCallbacks *cb){
  return guarded(cb,[&](Context &ctx){return extract(path,nullptr,nullptr,0,password,true,ctx);});
}
