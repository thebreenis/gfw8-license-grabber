#include <windows.h>
#include <oleauto.h>
#include <appmodel.h>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <algorithm>
#include <cwctype>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.ApplicationModel.Core.h>
#include <winrt/Windows.ApplicationModel.Activation.h>
#include <winrt/Windows.UI.Core.h>
#include <winrt/Windows.Security.Authentication.OnlineId.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Security.Cryptography.h>
#include <winrt/Windows.Security.Cryptography.Core.h>
using Build=void*(__fastcall*)(BSTR*,const wchar_t*,const wchar_t*,unsigned);
std::wstring manualSession;
DWORD invoke(Build fn,BSTR* out,const wchar_t* ticket,const wchar_t* receipt,unsigned title){
 __try{fn(out,ticket,receipt,title);return 0;}__except(EXCEPTION_EXECUTE_HANDLER){return GetExceptionCode();}
}
std::wstring wide(std::string const& s){
 // Consume the UTF-8 encoding preamble, matching ReadAllText/StreamReader.
 // Preserve all actual XML characters, including its leading CRLF and whitespace.
 size_t offset=s.size()>=3 && static_cast<unsigned char>(s[0])==0xef && static_cast<unsigned char>(s[1])==0xbb && static_cast<unsigned char>(s[2])==0xbf?3:0;
 int length=static_cast<int>(s.size()-offset);
 int n=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s.data()+offset,length,nullptr,0);
 if(!n && length)winrt::throw_last_error();
 std::wstring w(n,0);MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s.data()+offset,length,w.data(),n);return w;
}
void finish(std::wstring const& local,std::string const& result,UINT code){
 {std::ofstream out(std::filesystem::path(local+L"output.txt"),std::ios::binary);out<<result<<std::endl;}
 ExitProcess(code);
}
winrt::fire_and_forget RunSession(std::wstring session,winrt::Windows::UI::Core::CoreDispatcher dispatcher){
 // Yield activation, then initiate OnlineId on the CoreApplication UI thread.
 // Await completion through the normal dispatcher instead of nested ProcessEvents.
 co_await winrt::resume_foreground(dispatcher);
 std::wstring local;
 try{
  local=std::wstring(winrt::Windows::Storage::ApplicationData::Current().LocalFolder().Path())+L"\\";
  if(!session.empty()){
   if(session.size()!=32 || session.find_first_not_of(L"0123456789abcdef")!=std::wstring::npos)ExitProcess(23);
   local+=L"sessions\\"+session+L"\\";
  }
  UINT32 familyLength=256;wchar_t familyBuffer[256]{};winrt::check_win32(GetCurrentPackageFamilyName(&familyLength,familyBuffer));
  HANDLE processToken=nullptr;DWORD isContainer=0,returned=0;
  if(OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&processToken)){GetTokenInformation(processToken,TokenIsAppContainer,&isContainer,sizeof(isContainer),&returned);CloseHandle(processToken);}
  {std::ofstream context(std::filesystem::path(local+L"context.txt"));context<<"family="<<winrt::to_string(familyBuffer)<<" appContainer="<<isContainer<<std::endl;}
  std::ifstream input(std::filesystem::path(local+L"input.txt"),std::ios::binary);
  if(!input)ExitProcess(21);
  std::string ticketLine,receiptBytes;std::getline(input,ticketLine);
  receiptBytes.assign(std::istreambuf_iterator<char>(input),std::istreambuf_iterator<char>());input.close();
  auto ticket=wide(ticketLine),receipt=wide(receiptBytes);
  unsigned long long configured=1496516562;
  std::ifstream titleFile(std::filesystem::path(local+L"title.txt"));
  if(titleFile){titleFile>>configured;if(!titleFile || !configured || configured>0xffffffffULL)throw winrt::hresult_invalid_argument();}
  unsigned title=static_cast<unsigned>(configured);
  std::string sdkProfile="Jetpack2012";std::ifstream profileFile(std::filesystem::path(local+L"profile.txt"));if(profileFile)std::getline(profileFile,sdkProfile);
  if(sdkProfile!="Jetpack2012" && sdkProfile!="Win81" && sdkProfile!="Win81Root")throw winrt::hresult_invalid_argument();
  if(ticket==L"NATIVE_ONLINEID" || ticket==L"NATIVE_ONLINEID_REAUTH" || ticket==L"NATIVE_ONLINEID_PROMPT_IF_NEEDED"){
   bool reauthenticate=ticket==L"NATIVE_ONLINEID_REAUTH";
   bool promptIfNeeded=ticket==L"NATIVE_ONLINEID_PROMPT_IF_NEEDED";
   auto promptType=reauthenticate?winrt::Windows::Security::Authentication::OnlineId::CredentialPromptType::RetypeCredentials:(promptIfNeeded?winrt::Windows::Security::Authentication::OnlineId::CredentialPromptType::PromptIfNeeded:winrt::Windows::Security::Authentication::OnlineId::CredentialPromptType::DoNotPrompt);
   using namespace winrt::Windows::Security::Authentication::OnlineId;
   auto authWindow=winrt::Windows::UI::Core::CoreWindow::GetForCurrentThread();
   // Silent acquisition never activates the window.
   // Interactive recovery activates it before requesting Windows sign-in.
   if(reauthenticate || promptIfNeeded)authWindow.Activate();
   {std::ofstream ui(std::filesystem::path(local+L"ui.txt"));ui<<"prompt="<<(reauthenticate?"RetypeCredentials":(promptIfNeeded?"PromptIfNeeded":"DoNotPrompt"))<<" visibleBefore="<<authWindow.Visible()<<std::endl;}
   OnlineIdAuthenticator auth;
   auto requests=winrt::single_threaded_vector<OnlineIdServiceTicketRequest>();
   requests.Append(OnlineIdServiceTicketRequest(L"xbox.basic",L"DELEGATION"));
   auto identity=co_await auth.AuthenticateUserAsync(requests,promptType);
   co_await winrt::resume_foreground(dispatcher);
   {std::ofstream ui(std::filesystem::path(local+L"ui.txt"),std::ios::app);ui<<"visibleAfter="<<authWindow.Visible()<<std::endl;}
   // Account diagnostics contain only capability/result flags, never identity values.
   {std::ofstream status(std::filesystem::path(local+L"account-status.txt"));
    try{status<<"canSignOut="<<auth.CanSignOut()<<"\n";}catch(winrt::hresult_error const& e){status<<"canSignOutError="<<std::hex<<unsigned(e.code().value)<<std::dec<<"\n";}
    try{
     std::wstring name=identity.SignInName().c_str();
     std::string expectedBytes;std::ifstream expectedFile(std::filesystem::path(local+L"expected-account.txt"));std::getline(expectedFile,expectedBytes);
     auto expected=wide(expectedBytes);
     std::transform(name.begin(),name.end(),name.begin(),[](wchar_t c){return std::towlower(c);});
     std::transform(expected.begin(),expected.end(),expected.begin(),[](wchar_t c){return std::towlower(c);});
     status<<"signInNameAvailable="<<!name.empty()<<"\n";
     if(!expected.empty())status<<"matchesExpected="<<(!name.empty() && name==expected)<<"\n";
    }catch(winrt::hresult_error const& e){status<<"signInNameError="<<std::hex<<unsigned(e.code().value)<<std::dec<<"\n";}
   }
   // Optional metadata-only account comparison. Never persist names or account IDs.
   if(std::filesystem::exists(std::filesystem::path(local+L"compare-account.txt"))){
    try{
     std::wstring account=identity.Id().c_str(),name=identity.SignInName().c_str();
     auto hash=[&](std::wstring value){
      std::transform(value.begin(),value.end(),value.begin(),[](wchar_t c){return std::towlower(c);});
      auto bytes=winrt::Windows::Security::Cryptography::CryptographicBuffer::ConvertStringToBinary(session+L":"+value,winrt::Windows::Security::Cryptography::BinaryStringEncoding::Utf8);
      auto provider=winrt::Windows::Security::Cryptography::Core::HashAlgorithmProvider::OpenAlgorithm(L"SHA256");
      return winrt::to_string(winrt::Windows::Security::Cryptography::CryptographicBuffer::EncodeToHexString(provider.HashData(bytes)));
     };
     std::ofstream accountMeta(std::filesystem::path(local+L"account-comparison.txt"));
     accountMeta<<account.size()<<" "<<name.size()<<"\n"<<hash(account)<<"\n"<<hash(name)<<"\n";
    }catch(winrt::hresult_error const& e){std::ofstream accountMeta(std::filesystem::path(local+L"account-comparison.txt"));accountMeta<<"ERROR "<<std::hex<<unsigned(e.code().value)<<std::endl;}
   }
   if(identity.Tickets().Size()!=1)throw winrt::hresult_error(E_UNEXPECTED);
   auto native=identity.Tickets().GetAt(0);winrt::check_hresult(native.ErrorCode());
   ticket=native.Value().c_str();if(ticket.empty())throw winrt::hresult_error(E_UNEXPECTED);
   // Original SDK literal at RVA 0x31db8c, referenced by RVA 0x1465ed.
   ticket=L"d="+ticket;
   std::ofstream ticketFile(std::filesystem::path(local+L"ticket.txt"),std::ios::binary);
   for(auto c:ticket){if(c>127)throw winrt::hresult_error(E_UNEXPECTED);ticketFile<<char(c);}
   ticketFile.close();
  }
  SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOGPFAULTERRORBOX|SEM_NOOPENFILEERRORBOX);
  IUnknown* warm=nullptr;IStream* stream=nullptr;
  HRESULT hr=CoCreateFreeThreadedMarshaler(nullptr,&warm);
  if(SUCCEEDED(hr))hr=CoMarshalInterThreadInterfaceInStream(IID_IUnknown,warm,&stream);
  if(stream)stream->Release();if(warm)warm->Release();winrt::check_hresult(hr);
  wchar_t exe[MAX_PATH];GetModuleFileNameW(nullptr,exe,MAX_PATH);
  auto dep=std::filesystem::path(exe).parent_path().wstring();if(sdkProfile=="Win81")dep+=L"\\sdk-win81";SetDllDirectoryW(dep.c_str());
  auto sdk=LoadLibraryExW((dep+L"\\Microsoft.Xbox.dll").c_str(),nullptr,LOAD_WITH_ALTERED_SEARCH_PATH);
  if(!sdk)winrt::throw_last_error();
  {std::ofstream meta(std::filesystem::path(local+L"metadata.txt"));meta<<"ticket="<<ticket.size()<<" receipt="<<receipt.size()<<" title="<<title<<std::endl;}
  const size_t payloadRva=sdkProfile=="Jetpack2012"?0x14800c:0x177406;
  BSTR output=nullptr;DWORD error=invoke(reinterpret_cast<Build>(reinterpret_cast<char*>(sdk)+payloadRva),&output,ticket.c_str(),receipt.c_str(),title);
  if(error){std::ostringstream text;text<<"ERROR invoke "<<std::hex<<error;finish(local,text.str(),4);}
  if(!output)throw winrt::hresult_error(E_UNEXPECTED);
  std::string payload;for(unsigned i=0;i<SysStringLen(output);i++){if(output[i]>127)throw winrt::hresult_error(E_UNEXPECTED);payload+=char(output[i]);}
  SysFreeString(output);finish(local,payload,0);
 }catch(winrt::hresult_error const& e){std::ostringstream text;text<<"ERROR native helper "<<std::hex<<unsigned(e.code().value);finish(local,text.str(),9);}
 catch(...){finish(local,"ERROR native helper unexpected exception",12);}
}
struct ProbeView : winrt::implements<ProbeView,winrt::Windows::ApplicationModel::Core::IFrameworkView>{
 winrt::Windows::UI::Core::CoreWindow window{nullptr};
 void Initialize(winrt::Windows::ApplicationModel::Core::CoreApplicationView const& view){
  view.Activated([this](auto const&,winrt::Windows::ApplicationModel::Activation::IActivatedEventArgs const& args){
   if(!manualSession.empty())return;
   auto launch=args.try_as<winrt::Windows::ApplicationModel::Activation::LaunchActivatedEventArgs>();
   RunSession(launch?std::wstring(launch.Arguments()):L"",window.Dispatcher());
  });
 }
 void SetWindow(winrt::Windows::UI::Core::CoreWindow const& w){window=w;}
 void Load(winrt::hstring const&){}
 void Run(){if(!manualSession.empty()){RunSession(manualSession,window.Dispatcher());}window.Dispatcher().ProcessEvents(winrt::Windows::UI::Core::CoreProcessEventsOption::ProcessUntilQuit);}
 void Uninitialize(){}
};
struct ProbeSource : winrt::implements<ProbeSource,winrt::Windows::ApplicationModel::Core::IFrameworkViewSource>{
 winrt::Windows::ApplicationModel::Core::IFrameworkView CreateView(){return winrt::make<ProbeView>();}
};
int wmain(int argc,wchar_t** argv){
 winrt::init_apartment(winrt::apartment_type::multi_threaded);
 if(argc==3 && std::wstring(argv[1])==L"--manual-session"){
  manualSession=argv[2];if(manualSession.size()!=32 || manualSession.find_first_not_of(L"0123456789abcdef")!=std::wstring::npos)return 23;
  try{
   auto local=std::wstring(winrt::Windows::Storage::ApplicationData::Current().LocalFolder().Path())+L"\\sessions\\"+manualSession+L"\\context.txt";
   std::ofstream context{std::filesystem::path(local)};UINT32 length=0;context<<"packageStatus="<<GetCurrentPackageFullName(&length,nullptr)<<std::endl;
   HANDLE token=nullptr;DWORD isContainer=0,bytes=0;if(OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token)){GetTokenInformation(token,TokenIsAppContainer,&isContainer,sizeof(isContainer),&bytes);CloseHandle(token);}context<<"isAppContainer="<<isContainer<<std::endl;
  }catch(winrt::hresult_error const&){return 24;}
 }
 winrt::Windows::ApplicationModel::Core::CoreApplication::Run(winrt::make<ProbeSource>());
}
