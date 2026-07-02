const passwordInput = document.getElementById('password-input');
const togglePassword = document.getElementById('toggle-password');
const confirmInput = document.getElementById('password-input-confirm');

togglePassword.addEventListener('click', function() {
  const type = passwordInput.getAttribute('type') === 'password' ? 'text' : 'password';
  passwordInput.setAttribute('type', type);
  confirmInput.setAttribute('type', type); // 確認用も同時に切り替え

// アイコンの見た目（クラス）を切り替える
    if (type === 'password') {
        // パスワードが隠れている時は「普通の目」
        this.classList.remove('fa-eye-slash');
        this.classList.add('fa-eye');
    } else {
        // パスワードが見えている時は「斜線が入った目」
        this.classList.remove('fa-eye');
        this.classList.add('fa-eye-slash');
    }
});
