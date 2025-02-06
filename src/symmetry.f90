module symmetry
    use, intrinsic :: iso_fortran_env, only: dp => real64, i8 => int64
    use variables
    use hamiltonian
    use class_observables
    use dynamics
    use m_random
    use moments
    implicit none
    private
    public :: symmetrised_dynamics

    contains
    
    subroutine symmetrised_dynamics(sys, sim, rng, res, output_folder)
    ! Run quantum mechanical dynamics with trace sampling
        type(sys_param), intent(in)              :: sys 
        type(sim_param), intent(inout)           :: sim 
        type(RNG_t), intent(inout)               :: rng
        type(observables), intent(out)           :: res 
        character(:), allocatable, intent(inout) :: output_folder ! Folder where all experimental data will be saved

        integer(i8)                    :: Z
        integer                        :: N_steps
        real(dp), allocatable          :: a1_bar(:), a2_bar(:)
        integer, allocatable           :: n1_bar(:), n2_bar(:)
        integer, allocatable           :: K1(:,:), K2(:,:) 
        integer                        :: Z_current
        integer                        :: w_k
        type(sys_param)                :: sys_new
        type(observables), allocatable :: res_current(:)

        integer :: i, j


        ! Need to use 64-bit integer to calculate Z for large number of spins
        Z = product(int(sys%e1%g_I,kind=i8))*product(int(sys%e2%g_I,kind=i8))
        print*, real(Z, kind=dp)

        N_steps = ceiling((sim%t_end+sim%dt)/sim%dt)
        call res%malloc(N_steps+1)
        call res%set(0.0_dp)

        if (any(sys%e1%g_I /= 2) .or. any(sys%e2%g_I /= 2)) stop 'Method has not been implemented for nuclei with I>1/2.'

        if (size(sys%e1%g_I) > 0) then
            allocate(a1_bar(sim%M1))
            allocate(n1_bar(sim%M1))
            call shrink(sys%e1%a_iso, sim%M1, size(sys%e1%g_I), a1_bar, n1_bar)
            call cartesian_product(n1_bar, K1)
        else
            allocate(a1_bar(0))
            allocate(n1_bar(0))
            allocate(K1(1,1), source=1)
        end if

        if (size(sys%e2%g_I) > 0) then
            allocate(a2_bar(sim%M2))
            allocate(n2_bar(sim%M2))
            call shrink(sys%e2%a_iso, sim%M2, size(sys%e2%g_I), a2_bar, n2_bar)
            call cartesian_product(n2_bar, K2)
        else
            allocate(a2_bar(0))
            allocate(n2_bar(0))
            allocate(K2(0,1), source=1)
        end if

        ! allocate(sys_current(size(K1,dim=2)))
        allocate(res_current(size(K1,dim=2)))

        do j=1,size(K2,dim=2)
            !$OMP PARALLEL DO SHARED(sys,sim, rng, K1, K2, a1_bar, a2_bar, n1_bar, n2_bar, Z)&
            !$OMP& PRIVATE(sys_new,w_k, Z_current)
            do i=1,size(K1,dim=2)
                print*, 'starting new process'     
                w_k = weight(n1_bar, K1(:,i)) * weight(n2_bar, K2(:,j))
                Z_current = product(K1(:,i)) * product(K2(:,j))

                if (real(w_k*Z_current, kind=dp)/real(Z, kind=dp) > sim%block_tol) then

                    call reduce_system(sys, K1(:,i), a1_bar, K2(:,j), a2_bar, sys_new)

                    if (Z_current <= sim%N_samples) then
                        call exact_dynamics(sys_new, sim, res_current(i), output_folder)
                    else 
                        call trace_sampling(sys_new, sim, rng, res_current(i), output_folder)
                    end if
                    ! Weight result of simulation 
                    call res_current(i)%scale(real(w_k*Z_current, kind=dp))
                else
                    call res_current(i)%malloc(N_steps+1)
                    call res_current(i)%set(0.0_dp)
                end if
            end do
            !$OMP END PARALLEL DO
        end do

        do i=1,size(K1,dim=2)
            call res%update(res_current(i))        
        end do

        call res%scale(1.0_dp/real(Z, kind=dp))
        call res%get_kinetics(sim%dt, sys%kS, sys%kT)
        call res%output(output_folder)

    end subroutine symmetrised_dynamics

    subroutine reduce_system(sys, g_I1, a1_iso, g_I2, a2_iso, sys_new)
        type(sys_param), intent(in)  :: sys 
        integer, intent(in)          :: g_I1(:), g_I2(:)
        real(dp), intent(in)         :: a1_iso(:), a2_iso(:)
        type(sys_param), intent(out) :: sys_new 

        sys_new%J = sys%J
        sys_new%D = sys%D
        sys_new%kS = sys%kS
        sys_new%kT = sys%kT

        allocate(sys_new%e1%g_I(size(g_I1)))
        allocate(sys_new%e1%a_iso(size(g_I1)))
        sys_new%e1%g_I = g_I1
        sys_new%e1%a_iso = a1_iso
        sys_new%e1%isotropic = .true.
        sys_new%Z1 = product(sys_new%e1%g_I)

        allocate(sys_new%e2%g_I(size(g_I2)))
        allocate(sys_new%e2%a_iso(size(g_I2)))
        sys_new%e2%g_I = g_I2
        sys_new%e2%a_iso = a2_iso
        sys_new%e2%isotropic = .true.
        sys_new%Z2 = product(sys_new%e2%g_I)

    end subroutine reduce_system

    subroutine cartesian_product(n, k)
    ! Generate cartesian product of size(n) sets, where the i-th set has n(i) elements (not exactly because elements of na )
        integer, intent(in) :: n(:)
        integer, allocatable, intent(out) :: k(:,:)

        integer :: combinations 
        integer :: repeat
        integer :: length
        integer :: start, finish
        integer :: i, j

        combinations = product(n/2+1)
        allocate(k(size(n), combinations))

        repeat = 1
        do i=1,size(n)
            start = 1
            finish = repeat
            do j=1,n(i)/2+1
                k(i, start:finish) = 2*(j-1)+1+modulo(n(i), 2) 
                start = start + repeat
                finish = finish + repeat
            end do

            length = finish - repeat

            start = length+1
            finish = 2*length
            do j=2,combinations/length
                k(i, start:finish) = k(i, 1:length) 
                start = start + length
                finish = finish + length
            end do

            repeat = repeat*(n(i)/2+1)
        end do

    end subroutine cartesian_product

    function weight(n, k) result(w)
        integer, intent(in) :: n(:)
        integer, intent(in) :: k(:)
        integer :: w

        integer :: w_i
        integer  :: i

        w = 1
        do i=1,size(n)
            w_i = (nCr(n(i), (n(i) + k(i) - 1)/2)*k(i)*2)/(n(i)+k(i)+1)                        
            w = w*w_i
        end do

    end function weight

    function nCr(n, r) result(C)
        integer, intent(in) :: n
        integer, intent(in) :: r
        integer             :: C

        integer :: numer
        integer :: denom
        integer :: i

        numer = 1
        denom = 1
        
        do i=1,min(n-r,r)
            numer = numer*(n-i+1)
            denom = denom*i
        end do

        C = numer/denom

    end function nCr

end module symmetry